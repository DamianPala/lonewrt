# R41, R41a, R41b, R41c: /speedtest through the passes of the service with a fake client
# (tests/notify/stubs/speedtest) and a fake wwan0 counter. The R41 scenario word for word, the
# previous result only from the same day, the /status line only from today, a second command while
# a test runs, EDGE, every kind of failure with the result of the plain ping, the verdict
# thresholds, the server line, and that a test writes nothing to flash or syslog (R34c, R41b).
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup 7.50
lw_net up down
wifi_set 1
passes 2

# status: ask /status, return the answer
status() {
    tg_push "$TG_CHAT" /status
    pass
    last_text
}
# line_of TEXT PREFIX: the first line of TEXT that starts with PREFIX
line_of() { printf '%s\n' "$1" | grep -m 1 -- "^$2" || :; }
# line_after TEXT PREFIX / line_before TEXT PREFIX: the line under / above the first one that starts
# with PREFIX
line_after() { printf '%s\n' "$1" | awk -v p="$2" 'f { print; exit } index($0, p) == 1 { f = 1 }'; }
line_before() {
    printf '%s\n' "$1" | awk -v p="$2" 'index($0, p) == 1 { print q; exit } { q = $0 }'
}

# flash_state: every file under /etc and /root with its inode and content hash
flash_state() {
    find /etc /root -type f -exec ls -li {} + | sort
    find /etc /root -type f -exec md5sum {} + | sort
}
flash_before=$(flash_state)

# ---- the R41 scenario: 11:40 with 129/61, then 17:52 with 99/62 and ping 16 ms
wall_set '2026-11-07 11:40'
st_json 129.4 61.2 14 2
echo 190000000 >"$T/speedtest/rx"
echo 100000000 >"$T/speedtest/tx"
st_run
expect_sent 2
lw_expect_eq "$(sent_text 1)" "⏱ Speed test started, result in about 60 s." "first reply"
lw_expect_eq "$(sent_text 2)" "🚀 Speed test: fast

⬇️ Download: 129 Mbit/s
⬆️ Upload: 61 Mbit/s
📶 Ping: 14 ms (jitter 2 ms)
✅ Enough for 4K video on several devices and video calls

Server: Example Telecom, Springfield (7 km) · ~290 MB used" "first result, no previous"

wall_set '2026-11-07 17:52'
st_json 98.81 62.32 16 1
echo 196000000 >"$T/speedtest/rx"
echo 134000000 >"$T/speedtest/tx"
st_run
expect_sent 4
lw_expect_eq "$(sent_text 3)" "⏱ Speed test started, result in about 60 s." "second reply"
lw_expect_eq "$(sent_text 4)" "🚀 Speed test: fast

⬇️ Download: 99 Mbit/s
⬆️ Upload: 62 Mbit/s
📶 Ping: 16 ms (jitter 1 ms)
✅ Enough for 4K video on several devices and video calls

Previous today: 129 ⬇️ / 61 ⬆️ (11:40)
Server: Example Telecom, Springfield (7 km) · ~330 MB used" "the R41 scenario result"

# /help lists the command
tg_push "$TG_CHAT" /help
pass
expect_last '/speedtest – measure the internet speed (~60 s)'

# /status: the line sits right under the balance lines
s=$(status)
lw_expect_eq "$(line_of "$s" '🚀')" \
    "🚀 Speed test: 99 ⬇️ / 62 ⬆️ Mbit/s · ping 16 ms (today 17:52)" "status line"
case $(line_after "$s" '💶') in
    '🚀 Speed test:'*) ;;
    *) lw_fail "status line not under the balance" ;;
esac
# the data line of R44 follows it, and the start time follows that
case $(line_before "$s" '📊') in
    '🚀 Speed test:'*) ;;
    *) lw_fail "status line not above the data line" ;;
esac
case $(line_before "$s" '⏱ On') in
    '📊 Data this month:'*) ;;
    *) lw_fail "data line not above uptime" ;;
esac
# the layout has two empty lines (after the verdict, before Tech) and the line adds none
lw_expect_eq "$(printf '%s\n' "$s" | grep -c '^$')" 2 "empty lines in /status"

# after midnight both lines are gone: no status line, and the next result has no "Previous today"
wall_set '2026-11-08 00:05'
s=$(status)
case $s in *'Speed test'*) lw_fail "yesterday's test in /status after midnight: $s" ;; esac
lw_expect_eq "$(line_of "$s" '💶')" "💶 Balance: unknown" "the rest of /status is intact"
st_run
case $(last_text) in *'Previous today'*) lw_fail "yesterday's test as Previous today" ;; esac
lw_expect_eq "$(line_of "$(last_text)" 'Server')" \
    "Server: Example Telecom, Springfield (7 km) · ~330 MB used" "server line"
lw_expect_eq "$(line_of "$(status)" '🚀')" \
    "🚀 Speed test: 99 ⬇️ / 62 ⬆️ Mbit/s · ping 16 ms (today 00:05)" "status line of the new day"
# the same day again: now it is the previous one
wall_set '2026-11-08 09:30'
st_json 47.2 20 22 4
st_run
case $(last_text) in
    *'Previous today: 99 ⬇️ / 62 ⬆️ (00:05)'*) ;;
    *) lw_fail "no Previous today on the same day: $(last_text)" ;;
esac
# the time markers: a status line that is read the next day says yesterday only when shown, and it
# is not shown then
wall_set '2026-11-09 00:01'
case $(status) in *'Speed test'*) lw_fail "two-day-old test in /status" ;; esac

# ---- the verdict thresholds on the rounded download (R41a): value, verdict, "Enough for" line
wall_set '2026-11-09 10:00'
check() {
    st_json "$1" 10 20 1
    st_run
    lw_expect_eq "$(line_of "$(last_text)" '🚀')" "🚀 Speed test: $2" "verdict for $1"
    lw_expect_eq "$(last_text | grep -m 1 'Enough for')" "$3" "Enough-for line for $1"
}
check 120 fast '✅ Enough for 4K video on several devices and video calls'
check 49.6 fast '✅ Enough for 4K video on several devices and video calls'
check 49.4 OK '✅ Enough for HD video and video calls'
check 10 OK '✅ Enough for HD video and video calls'
check 9.4 slow '⚠️ Enough for browsing and low-quality video'
check 2 slow '⚠️ Enough for browsing and low-quality video'
check 1.6 slow '⚠️ Enough for browsing and low-quality video'
check 1.4 'very slow' '❌ Enough for messages only'
check 0 'very slow' '❌ Enough for messages only'
lw_expect_eq "$(line_of "$(last_text)" '⬇️')" "⬇️ Download: 0 Mbit/s" "zero download"

# ---- the server line: company form, a missing server, no counter
st_json 80 40 20 1 'Foo DOO' Bar 12
st_run
lw_expect_eq "$(line_of "$(last_text)" 'Server')" "Server: Foo, Bar (12 km) · ~330 MB used" "DOO"
st_json 80 40 20 1 'Telekom d.o.o.' Bar 12
st_run
lw_expect_eq "$(line_of "$(last_text)" 'Server')" \
    "Server: Telekom, Bar (12 km) · ~330 MB used" "d.o.o."
st_json 80 40 20 1 'Plain Name' Bar 12
st_run
lw_expect_eq "$(line_of "$(last_text)" 'Server')" \
    "Server: Plain Name, Bar (12 km) · ~330 MB used" "no suffix"
echo '{"ping":5,"jitter":1,"download_mbit":80.2,"upload_mbit":40.1}' >"$T/speedtest/json"
st_run
lw_expect_eq "$(line_of "$(last_text)" 'Server')" "Server: unknown · ~330 MB used" "no server"
st_json 80 40 20 1
mv "$T/wwan0/rx_bytes" "$T/wwan0/rx.off"
st_run
lw_expect_eq "$(line_of "$(last_text)" 'Server')" "Server: Example Telecom, Springfield (7 km)" \
    "no counter, no data use"
mv "$T/wwan0/rx.off" "$T/wwan0/rx_bytes"
# the tool prints a banner before the JSON: the last line that starts with "{" is the answer
st_mode banner
st_run
lw_expect_eq "$(line_of "$(last_text)" '🚀')" "🚀 Speed test: fast" "banner before the JSON"
st_mode ok

# ---- a second command while a test runs (R41c): one answer, one run
n=$(sent)
calls=$(st_calls)
st_mode ok 3
tg_push "$TG_CHAT" /speedtest
pass
tg_push "$TG_CHAT" /speedtest
pass
tg_push "$TG_CHAT" /speedtest
pass
lw_expect_eq "$(sent)" $((n + 3)) "started + two already-running answers"
lw_expect_eq "$(sent_text $((n + 1)))" "⏱ Speed test started, result in about 60 s." "start"
running="⏳ A speed test is already running, the result comes in a moment."
lw_expect_eq "$(sent_text $((n + 2)))" "$running" "second command"
lw_expect_eq "$(sent_text $((n + 3)))" "$running" "third command"
lw_expect_eq "$(st_calls)" $((calls + 1)) "the client runs once"
st_wait
pass
lw_expect_eq "$(sent)" $((n + 4)) "the result of the one test"
case $(last_text) in '🚀 Speed test:'*) ;; *) lw_fail "no result: $(last_text)" ;; esac
# and the next command starts a new test again
st_mode ok 0
st_run
lw_expect_eq "$(st_calls)" $((calls + 2)) "a new test after the first ended"

# ---- EDGE (R41c): no test, the 2G message
calls=$(st_calls)
n=$(sent)
: >/tmp/lw-edge
tg_push "$TG_CHAT" /speedtest
pass
lw_expect_eq "$(sent)" $((n + 1)) "one reply on EDGE"
lw_expect_eq "$(last_text)" "🟠 Speed test skipped: the router is on the slow 2G backup.
/status shows the details." "EDGE reply"
sleep 1
lw_expect_eq "$(st_calls)" "$calls" "no test on EDGE"
no_orphans
rm -f /tmp/lw-edge
st_run
lw_expect_eq "$(st_calls)" $((calls + 1)) "tests again after EDGE"

# ---- failures (R41c): every kind gives one message with the result of the plain ping
# failed TEXT LABEL: the command ran; the chat got "started" and then TEXT
failed() {
    n=$(sent)
    st_run
    lw_expect_eq "$(sent)" $((n + 2)) "started + failure ($2)"
    lw_expect_eq "$(last_text)" "$1" "$2"
}
st_mode fail
failed "❌ Speed test failed: no speedtest.net server answered.
The internet itself works (ping 36 ms), try again later." "exit 1, internet up"
st_mode garbage
failed "❌ Speed test failed: no speedtest.net server answered.
The internet itself works (ping 36 ms), try again later." "garbage output"
st_mode nodl
failed "❌ Speed test failed: no speedtest.net server answered.
The internet itself works (ping 36 ms), try again later." "JSON without download_mbit"
lw_net down down
st_mode fail
failed "❌ Speed test failed: no speedtest.net server answered.
The internet itself does not work either (no answer to ping), try again later." "internet down"
lw_net up down
# a good result stays "last" through a failed test: /status still shows it
wall_set '2026-11-09 10:30'
st_mode ok
st_json 99 62 16 1
st_run
st_mode fail
st_run
case $(status) in *'🚀 Speed test: 99 ⬇️ / 62 ⬆️ Mbit/s · ping 16 ms (today 10:30)'*) ;; *)
    lw_fail "a failed test changed the status line" ;; esac
# the client hangs: killed at the limit, the failure comes with the ping, nothing is left
st_mode hang
t0=$(date +%s)
st_run
took=$(elapsed_since "$t0")
lw_expect_eq "$(last_text)" "❌ Speed test failed: it did not finish in time.
The internet itself works (ping 36 ms), try again later." "hung client"
[ "$took" -le 12 ] || lw_fail "a hung client took $took s with a 5 s limit"
no_orphans
! pgrep -f 'stubs/speedtest|sleep 3601' >/dev/null || lw_fail "a speedtest process is left"
st_mode ok

# ---- a worker that vanished without a result (kill -9) leaves nothing that blocks the next test
st_mode ok 30
tg_push "$TG_CHAT" /speedtest
pass
pid=$(cat /tmp/lw-notify/speedtest.pid)
kill -9 "-$pid"
sleep 1
n=$(sent)
pass
lw_expect_eq "$(sent)" $((n + 1)) "one message for the killed test"
lw_expect_eq "$(last_text)" "❌ Speed test failed: it did not finish in time.
Try again later." "killed worker"
[ ! -e /tmp/lw-notify/speedtest.pid ] || lw_fail "pid file of the killed test kept"
st_mode ok 0
st_run
case $(last_text) in '🚀 Speed test:'*) ;; *) lw_fail "no test after a killed one" ;; esac
# a pid file that names a live, unrelated process is no lock either
sleep 100 &
other=$!
echo "$other" >/tmp/lw-notify/speedtest.pid
st_run
case $(last_text) in '🚀 Speed test:'*) ;; *) lw_fail "a foreign pid blocked the test" ;; esac
kill "$other" 2>/dev/null || :
# a pid file of a process that is gone, as a crashed service leaves it
echo 99999 >/tmp/lw-notify/speedtest.pid
n=$(sent)
pass
lw_expect_eq "$(sent)" $((n + 1)) "the leftover of a dead worker is reported once"
pass
lw_expect_eq "$(sent)" $((n + 1)) "and not again"
st_run
case $(last_text) in '🚀 Speed test:'*) ;; *) lw_fail "no test after a stale pid file" ;; esac

# ---- no clock from NTP: the result has no "Previous", /status has no line (nothing is "today")
ntp_off
st_run
case $(last_text) in *'Previous today'*) lw_fail "Previous today without a clock" ;; esac
case $(status) in *'Speed test:'*) lw_fail "status line without a clock" ;; esac
ntp_on

# ---- R34c, R34d: no flash write, no syslog entry, no token anywhere
lw_expect_eq "$(flash_state)" "$flash_before" "flash after the tests"
lw_expect_eq "$(cat "$T/syslog")" "" "syslog after the tests"
hits=$(grep -rlF TESTtokq7x9 /etc /root /tmp 2>/dev/null | grep -v '^/etc/config/lonewrt$' || :)
[ -z "$hits" ] || lw_fail "token in $hits"
sleep 1
no_orphans

# ---- Telegram down when the result is ready: it waits and goes out when Telegram is back
tg_push "$TG_CHAT" /speedtest
pass
echo down >"$G/net"
st_wait
passes 2
n=$(sent)
echo up >"$G/net"
pass
lw_expect_eq "$(sent)" $((n + 1)) "the result goes out when Telegram is back"
case $(last_text) in '🚀 Speed test:'*) ;; *) lw_fail "late result: $(last_text)" ;; esac
pass
lw_expect_eq "$(sent)" $((n + 1)) "and only once"
echo ok
