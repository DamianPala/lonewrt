# R42: the heartbeat. With an address in uci lonewrt.heartbeat.url, lw-heartbeat calls it once, quietly
# (-q: uclient-fetch would print the address otherwise), with a short limit; it writes nothing to
# syslog or flash and prints nothing, whether the call works, fails or hangs; without an address it
# does not call at all; it needs no Telegram keys. The address is a secret like the token (R4,
# R34d): it appears in no output, log or file but /etc/config/lonewrt (root-only since the first boot,
# tests/firstboot/full.sh).
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
lw_setup
PATH=/fw/tests/notify/stubs:$PATH
HC='https://hc-ping.fake-q7x9.example/FAKEhcping-q7x9-0001'
calls() { if [ -f "$T/hc/calls" ]; then wc -l <"$T/hc/calls" | tr -d ' '; else echo 0; fi; }
flash_state() {
    find /etc /root -type f -exec ls -li {} + | sort
    find /etc /root -type f -exec md5sum {} + | sort
}

# no address (the default image): not a single call, no output
rm -f /etc/config/lonewrt
touch /etc/config/lonewrt
out=$(lw-heartbeat 2>&1) || lw_fail "lw-heartbeat failed without an address"
lw_expect_eq "$out" "" "output without an address"
lw_expect_eq "$(calls)" 0 "calls without an address"
uci set lonewrt.heartbeat=heartbeat
uci commit lonewrt
out=$(lw-heartbeat 2>&1) || lw_fail "lw-heartbeat failed with an empty section"
lw_expect_eq "$(calls)" 0 "calls with a section but no address"
# an option that exists but is empty (a hand-edited file; uci reads it as no option) is no address
printf "config heartbeat 'heartbeat'\n\toption url ''\n" >/etc/config/lonewrt
out=$(lw-heartbeat 2>&1) || lw_fail "lw-heartbeat failed with an empty address"
lw_expect_eq "$out" "" "output with an empty address"
lw_expect_eq "$(calls)" 0 "calls with an empty address"
: >/etc/config/lonewrt
uci set lonewrt.heartbeat=heartbeat

# an address and no Telegram keys at all: one quiet call to exactly that address
uci set lonewrt.heartbeat.url="$HC"
uci commit lonewrt
lw_expect_eq "$(uci -q get lonewrt.notify.token || echo none)" none "test premise: no Telegram token"
before=$(flash_state)
out=$(lw-heartbeat 2>&1) || lw_fail "lw-heartbeat failed"
lw_expect_eq "$out" "" "output of a working call"
lw_expect_eq "$(calls)" 1 "calls"
lw_expect_eq "$(cat "$T/hc/calls")" "quiet $HC" "the call"
lw_expect_eq "$(flash_state)" "$before" "flash after a call"
lw_expect_eq "$(cat "$T/syslog")" "" "syslog after a call"

# failures change nothing and say nothing: no route, an HTTP error, a stuck server
for mode in down 500 429; do
    echo "$mode" >"$T/hc/mode"
    out=$(lw-heartbeat 2>&1) || lw_fail "lw-heartbeat failed with mode $mode"
    lw_expect_eq "$out" "" "output with mode $mode"
done
lw_expect_eq "$(calls)" 4 "calls after three failures"
lw_expect_eq "$(flash_state)" "$before" "flash after failed calls"
lw_expect_eq "$(cat "$T/syslog")" "" "syslog after failed calls"
echo hang >"$T/hc/mode"
t0=$(date +%s)
out=$(lw-heartbeat 2>&1) || lw_fail "lw-heartbeat failed with a stuck server"
lw_expect_eq "$out" "" "output with a stuck server"
[ "$(elapsed_since "$t0")" -le 25 ] || lw_fail "a stuck server held the heartbeat for $(elapsed_since "$t0") s"
! pgrep -f 'uclient-fetch|sleep 3600' >/dev/null || lw_fail "orphaned call after the limit"
lw_expect_eq "$(cat "$T/syslog")" "" "syslog after a stuck call"

# the address is a secret: nowhere but the root-only config (and the stub's own record)
hits=$(grep -rlF FAKEhcping /etc /root /tmp 2>/dev/null | grep -v '^/etc/config/lonewrt$' || :)
lw_expect_eq "$hits" "" "files with the address"

# independent of the notification code: the script does not load it
! grep -qE 'notify\.sh|lw-notify|TG_|lonewrt\.notify' /fw/src/files/usr/sbin/lw-heartbeat ||
    lw_fail "lw-heartbeat depends on the notification keys"
echo ok
