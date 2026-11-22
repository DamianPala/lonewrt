# R65a, R65e, R72a, D140, D154, D158: `lw-tailscale link` prints the link Tailscale gives now (exit 0),
# the state of an added router instead of a link (2), or the state when there is no link (3); a sign-in
# by hand goes through it and keeps the settings of R64; the link reaches nobody's log.
# shellcheck source=tests/tailscale/ts.inc
. /fw/tests/tailscale/ts.inc
ts_setup
URL=https://login.example.invalid/a/FAKELINK01
UP="up --timeout=25s $SET_ARGS --advertise-routes= --hostname=lw-test-rtr"

# not added: the link comes from `up`, which carries the settings; one line, exit 0
ts_backend NeedsLogin
echo url >"$D/up-mode"
rc=0
out=$(lw-tailscale link 2>"$T/err") || rc=$?
lw_expect_eq "$rc" 0 "exit code with a link"
lw_expect_eq "$out" "$URL" "the link"
lw_expect_eq "$(cat "$T/err")" "" "stderr of link"
lw_expect_eq "$(ts_calls)" "$UP" "the call that asks for the link"
[ ! -e /tmp/lw-tailscale/link.out ] || lw_fail "the output of up stays in RAM"
lw_expect_no_grep "$T/syslog" "http"
lw_expect_no_grep "$T/syslog" "FAKELINK"
ts_once
lw_expect_no_grep /tmp/lw-tailscale/state "http"
lw_expect_no_grep "$T/syslog" "FAKELINK"

# every request asks again: a new link on every request (D140)
rm -f "$D/calls" "$D/authurl"
lw-tailscale link >/dev/null
lw-tailscale link >/dev/null
lw_expect_eq "$(ts_count up)" 2 "up calls for two requests"

# an ended router gets a link as well (R68a)
ts_world
ts_added
ts_once
ts_backend NeedsLogin
echo url >"$D/up-mode"
rc=0
out=$(lw-tailscale link) || rc=$?
lw_expect_eq "$rc$out" "0$URL" "link of an ended router"

# up gives none but the daemon holds one: that one
ts_world
ts_backend NeedsLogin
echo noanswer >"$D/up-mode"
echo "$URL" >"$D/authurl"
rc=0
out=$(lw-tailscale link) || rc=$?
lw_expect_eq "$rc$out" "0$URL" "the link the daemon holds"

# no link at all: exit 3 and the state
rm -f "$D/authurl"
rc=0
out=$(lw-tailscale link) || rc=$?
lw_expect_eq "$rc" 3 "exit code without a link"
lw_expect_eq "$out" "state=not_added" "output without a link"

# a hung up ends after the wait and leaves no process behind
echo wait >"$D/up-mode"
rc=0
out=$(LW_TS_LINK_WAIT=3 lw-tailscale link) || rc=$?
lw_expect_eq "$rc$out" "3state=not_added" "a hung up"
! pgrep -f 'sleep 3600' >/dev/null || lw_fail "a hung up survived"
# R65a: the wait for the link ends 3 s before the bound, leaving time for the last read
: >"$T/sleeps"
rc=0
out=$(lw-tailscale link) || rc=$?
lw_expect_eq "$rc$(grep -c '^sleep 1$' "$T/sleeps")" "322" "seconds waited for a hung up"

# added: the state, never a link (D158), exit 2, and up is not called
ts_world
ts_added $((BASE + 100 * 86400))
echo url >"$D/up-mode"
rc=0
out=$(lw-tailscale link) || rc=$?
lw_expect_eq "$rc" 2 "exit code of an added router"
lw_expect_eq "$(printf '%s\n' "$out" | sed -n 's/^state=//p;s/^name=//p' | tr '\n' ' ')" "added rtr " "state and name"
lw_expect_eq "$(ts_calls)" "" "calls for an added router"
case $out in *http*) lw_fail "a link for an added router" ;; esac

# starting and not running: exit 3 and the state, no up
ts_backend Starting
rc=0
out=$(lw-tailscale link) || rc=$?
lw_expect_eq "$rc$out" "3state=starting" "while starting"
ts_down
rc=0
out=$(lw-tailscale link) || rc=$?
lw_expect_eq "$rc$out" "3state=not_running" "without a daemon"
lw_expect_eq "$(ts_count up)" 0 "up calls while starting or not running"

# the settings of a sign-in by hand with LAN advertised
ts_world
uci set lonewrt.tailscale.advertise_lan=1
uci commit lonewrt
ts_backend NeedsLogin
echo url >"$D/up-mode"
lw-tailscale link >/dev/null
lw_expect_eq "$(ts_calls)" "up --timeout=25s $SET_ARGS --advertise-routes=192.168.5.0/24 --hostname=lw-test-rtr" \
    "the call with the LAN offered"
echo ok
