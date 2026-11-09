# R34f: a message Telegram rejects (HTTP 400) must not block the queue. It goes once more as plain
# ASCII; when that is rejected too it is dropped with one lw-notify syslog line (ASCII, no token,
# no SMS content) and the next message goes. A 400 is not a link failure (no "unreachable"); a
# network failure, 5xx and 429 keep the old behaviour (the message waits, R34a). Each SMS goes at
# most once, also across a reboot in the middle of the retry. The fake bot's rules are in
# tests/notify/stubs/uclient-fetch.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup ''
passes 3

queue_n() { find /etc/lw-notify/queue -type f 2>/dev/null | wc -l | tr -d ' '; }
syslog_n() { grep -c "$1" "$T/syslog" || :; }
DROPPED='lw-notify: Telegram rejected a message (HTTP 400) twice, dropped it'

# first try rejected, ASCII retry accepted: one message, o-acute and symbols as ?, nothing logged
echo nonascii >"$G/reject400"
sms_in 0 +38200000001 '11/07/26 12:00:00' "$(printf 'm\303\263j')"
passes 2
expect_sent 1
lw_expect_eq "$(sent_text 1)" "?? +38200000001 ? Today 12:00

m?j" "ASCII retry text"
lw_expect_eq "$(rejected_n)" 1 "rejections"
lw_expect_eq "$(sendcalls)" 2 "sendMessage calls (rejected + ASCII retry)"
lw_expect_eq "$(queue_n)" 0 "queue"
lw_expect_eq "$(cat "$T/syslog")" "" "syslog after a message that needed the ASCII retry"
[ ! -e /tmp/lw-notify/down ] && [ ! -e /tmp/lw-notify/fail_since ] ||
    lw_fail "a 400 changed the link state"

# rejected twice: dropped with one log line, the next message goes in the same pass
echo 'has POISON' >"$G/reject400"
sms_in 1 +38200000002 '11/07/26 12:01:00' 'POISON pill'
sms_in 2 +38200000003 '11/07/26 12:01:05' 'fine after'
passes 2
expect_sent 2
lw_expect_eq "$(sent_text 2 | tail -n 1)" 'fine after' "message after the dropped one"
lw_expect_eq "$(rejected_n)" 3 "rejections"
lw_expect_eq "$(queue_n)" 0 "queue"
lw_expect_eq "$(wc -l <"$T/syslog" | tr -d ' ')" 1 "syslog lines"
lw_expect_grep "$T/syslog" "$DROPPED, 1 SMS still queued"
lw_expect_no_grep "$T/syslog" unreachable
lw_expect_no_grep "$T/syslog" POISON
[ -z "$(LC_ALL=C tr -d '\n\040-\176' <"$T/syslog")" ] || lw_fail "syslog line is not ASCII"

# the rejected one in the middle: order of the others stays
sms_in 3 +38200000004 '11/07/26 12:02:00' 'before'
sms_in 4 +38200000005 '11/07/26 12:02:05' 'POISON again'
sms_in 5 +38200000006 '11/07/26 12:02:10' 'after'
passes 2
expect_sent 4
lw_expect_eq "$(sent_text 3 | tail -n 1)" before "third sent"
lw_expect_eq "$(sent_text 4 | tail -n 1)" after "fourth sent"
lw_expect_eq "$(syslog_n "$DROPPED")" 2 "drop lines"
lw_expect_eq "$(syslog_n unreachable)" 0 "unreachable lines"

# the token appears nowhere: not in what the script prints, the syslog, RAM or flash state (the
# fake uclient-fetch prints the URL with the token on stderr, like the real one without -q)
sms_in 6 +38200000007 '11/07/26 12:03:00' 'POISON third'
out=$({ passes 2; } 2>&1)
lw_expect_eq "$(syslog_n "$DROPPED")" 3 "drop lines"
lw_expect_eq "$out" "" "output of the script on a rejected message"
! grep -rqF "$TG_TOKEN" "$T/syslog" /tmp/lw-notify /etc/lw-notify || lw_fail "token in a state file"
[ -z "$(find /tmp/lw-notify -name 'err.*')" ] || lw_fail "stderr file left behind"
: >"$T/syslog"

# 500 and 429 are not rejections: the message waits, one try per pass, no ASCII retry, no drop
for code in 500 429; do
    echo "$code" >"$G/status"
    n=$(sent)
    sms_in "1$code" +38200000008 '11/07/26 12:04:00' "waits on $code"
    passes 2
    lw_expect_eq "$(queue_n)" 1 "queued on $code"
    c=$(sendcalls)
    r=$(rejected_n)
    passes 3
    lw_expect_eq "$(($(sendcalls) - c))" 3 "sendMessage calls in 3 passes on $code"
    lw_expect_eq "$(rejected_n)" "$r" "rejections on $code"
    expect_sent "$n"
    lw_expect_eq "$(syslog_n unreachable)" 1 "unreachable lines on $code"
    lw_expect_eq "$(syslog_n "$DROPPED")" 0 "drop lines on $code"
    rm -f "$G/status"
    pass
    expect_sent $((n + 1))
    lw_expect_eq "$(queue_n)" 0 "queue after $code"
    lw_expect_eq "$(syslog_n 'Telegram reachable again')" 1 "reachable lines on $code"
    : >"$T/syslog"
done

# no network (R34a as before): queued, no rejection counted, no ASCII retry, delivered later
echo down >"$G/net"
r=$(rejected_n)
n=$(sent)
sms_in 20 +38200000009 '11/07/26 12:05:00' "$(printf 'wait m\303\263j')"
passes 3
lw_expect_eq "$(queue_n)" 1 "queued while down"
lw_expect_eq "$(rejected_n)" "$r" "rejections while down"
lw_expect_eq "$(syslog_n unreachable)" 1 "unreachable lines while down"
# back up, and the message is now rejected twice: the link is reported back, the message dropped
echo up >"$G/net"
echo 'has wait' >"$G/reject400"
passes 2
lw_expect_eq "$(queue_n)" 0 "queue after the drop"
expect_sent "$n"
lw_expect_eq "$(syslog_n unreachable)" 1 "unreachable lines after the drop"
lw_expect_eq "$(syslog_n 'Telegram reachable again')" 1 "reachable lines after the drop"
lw_expect_eq "$(syslog_n "$DROPPED")" 1 "drop lines after outage"
: >"$T/syslog"

# a reboot in the middle of the retry: the first try is rejected, the network drops before the
# retry, the router restarts; the message goes out once, not twice and not lost
echo nonascii >"$G/reject400"
: >"$G/down_after_reject"
n=$(sent)
sms_in 21 +38200000010 '11/07/26 12:06:00' "$(printf 'once k\303\263')"
passes 2
expect_sent "$n"
lw_expect_eq "$(queue_n)" 1 "queued after the cut retry"
lw_reboot_sim
rm -f "$G/down_after_reject"
echo up >"$G/net"
passes 2
expect_sent $((n + 1))
case $(last_text) in *'once k?') ;; *) lw_fail "retry text: $(last_text)" ;; esac
passes 3
lw_reboot_sim
passes 4
expect_sent $((n + 1))
lw_expect_eq "$(queue_n)" 0 "queue at the end"

# R34i: what the service leaves behind is for root only. The queue holds SMS texts, a request body
# holds an SMS text or the Wi-Fi password, and the stderr file next to it holds the token's URL; the
# new files and directories are made by the service itself, so the state of a first start is built
# from nothing
rm -r -f /etc/lw-notify "$G/body-modes"
lw_reboot_sim
passes 2
echo 500 >"$G/status"
sms_in 40 +38200000011 '11/07/26 12:10:00' 'mode check'
passes 3
[ -n "$(find /etc/lw-notify/queue -type f)" ] || lw_fail "no queue file to check the mode of"
[ -s "$G/body-modes" ] || lw_fail "no request body to check the mode of"
lw_expect_eq "$(find /etc/lw-notify /tmp/lw-notify -perm /077)" "" "state files and directories open to group or others"
lw_expect_eq "$(find /etc/lw-notify /tmp/lw-notify -type f | wc -l | tr -d ' ')" \
    "$(find /etc/lw-notify /tmp/lw-notify -type f -perm 600 | wc -l | tr -d ' ')" "state files with mode 0600"
# the bodies of the calls that went out, the Wi-Fi password among them
rm -f "$G/status"
tg_push "$TG_CHAT" /wifi
pass
lw_expect_eq "$(sort -u "$G/body-modes")" "-rw-------" "mode of the request bodies"
lw_expect_eq "$(find /etc/lw-notify /tmp/lw-notify -perm /077)" "" "files and directories after the sends"

no_orphans
echo ok
