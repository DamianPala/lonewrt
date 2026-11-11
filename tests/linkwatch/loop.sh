# R49: the service loop. A pass every 5 s; a loss that appears between two passes is seen by the next
# one and restored within it; the passes after it are healthy and silent. A loss that cannot be
# restored gets its one ifup, and the loop makes no more calls to start the network until a pass has
# seen the session healthy.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc

lk_setup
cat >"$T/on-sleep" <<'HOOK'
#!/bin/sh
n=$(cat /lwtest/naps 2>/dev/null || echo 0)
n=$((n + 1))
echo $n >/lwtest/naps
# the network detaches the modem after the first pass
[ "$n" != 1 ] || echo down >/lwtest/uqmi/session
HOOK
chmod +x "$T/on-sleep"
LW_LINKWATCH_PASSES=4 lw-linkwatch run
lw_expect_eq "$(tr '\n' ' ' <"$T/sleeps")" "sleep 5 sleep 1 sleep 5 sleep 5 " "naps: period, one in the incident, period, period"
lw_expect_eq "$(lk_info)" 1 "watcher syslog lines"
lw_expect_eq "$(lk_calls_of --start-network)" 1 "start-network calls"
lw_expect_eq "$(grep -c '^ifup' "$EVENTS" || true)" 0 "ifup events"

# unrestorable: one ifup over several passes
lk_setup
echo '"Call failed"' >"$T/uqmi/q-start"
lk_lost
LW_LINKWATCH_PASSES=6 lw-linkwatch run
lw_expect_eq "$(grep -c '^ifup wwan$' "$EVENTS")" 1 "ifup wwan events over six passes"
lw_expect_eq "$(lk_info)" 1 "watcher syslog lines"
lk_lines | grep -qE "not restored in place after 2[01] s, ifup wwan\$" || lw_fail "info line: $(lk_lines)"
# the loop is started again after a crash (procd respawn): the escalation is remembered, a healthy
# pass clears it, and a new loss is tried again
LW_LINKWATCH_PASSES=2 lw-linkwatch run
lw_expect_eq "$(grep -c '^ifup wwan$' "$EVENTS")" 1 "ifup wwan events after a restart of the loop"
lk_healthy
LW_LINKWATCH_PASSES=1 lw-linkwatch run
lk_lost
rm -f "$T/uqmi/q-start"
LW_LINKWATCH_PASSES=1 lw-linkwatch run
lw_expect_eq "$(lk_info)" 2 "watcher syslog lines after the second loss"
lk_lines | tail -n 1 | grep -qF "restored in place" || lw_fail "second loss: $(lk_lines | tail -n 1)"
echo ok
