# R49d: a session not restored 20 s after the loss was seen gets exactly one `ifup wwan` and one info
# line, and nothing more for this incident, however many passes follow; a new incident acts again
# only after a pass has seen the session healthy. A PDP type other than IPv4 goes straight to the
# escalation, and an `ip` or `ipv4` of any letter case does not.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc
ifups() { grep -c '^ifup wwan$' "$EVENTS" || true; }

# start-network never works
lk_setup
lk_lost
echo '"Call failed"' >"$T/uqmi/q-start"
lw-linkwatch once
lw_expect_eq "$(ifups)" 1 "ifup wwan events"
lw_expect_eq "$(cat "$EVENTS")" "ifup wwan" "events: nothing but the one ifup"
lw_expect_eq "$(lk_calls_of --start-network)" 10 "start-network calls in 20 s, one per 2 s"
lw_expect_eq "$(lk_info)" 1 "watcher syslog lines"
lk_lines | grep -qE " lw-linkwatch: data session lost, not restored in place after 20 s, ifup wwan\$" ||
    lw_fail "info line: $(lk_lines)"

# the passes that follow while the session is still lost do nothing (and ask nothing more of uqmi
# than the two reads)
: >"$CALLS"
lw-linkwatch once
lw-linkwatch once
lw_expect_eq "$(ifups)" 1 "ifup wwan events after more passes"
lw_expect_eq "$(lk_calls_of --start-network)" 0 "start-network calls after the escalation"
lw_expect_eq "$(lk_info)" 1 "watcher syslog lines after more passes"

# healthy again, then lost again: a new incident, and this time the start works
lk_healthy
lw-linkwatch once
lk_lost
rm -f "$T/uqmi/q-start"
lw-linkwatch once
lw_expect_eq "$(ifups)" 1 "ifup wwan events after the second incident"
lw_expect_eq "$(lk_info)" 2 "watcher syslog lines after the second incident"
lk_lines | tail -n 1 | grep -q 'start-network' && lw_fail "the log names start-network"
lk_lines | tail -n 1 | grep -qE "restored in place after" || lw_fail "second incident: $(lk_lines | tail -n 1)"

# the new address never reaches the device (udhcpc does not answer): the lease is asked for again
# every 6 s, and after 20 s there is the one ifup (the 1 s naps after a lease request shift the count)
lk_setup
lk_lost
touch "$T/dhcp-deaf"
lw-linkwatch once
lw_expect_eq "$(ifups)" 1 "ifup wwan events with a deaf udhcpc"
[ "$(grep -c '^kill USR1' "$EVENTS")" -ge 3 ] || lw_fail "the lease was not asked for again: $(cat "$EVENTS")"
lw_expect_eq "$(lk_calls_of --start-network)" 1 "start-network calls with a deaf udhcpc"
lk_lines | grep -qE "not restored in place after 2[01] s, ifup wwan\$" || lw_fail "info line: $(lk_lines)"

# a pid file that does not lead to udhcpc: nothing is signalled
lk_setup
lk_lost
/bin/sleep 100 &
echo $! >/var/run/udhcpc-wwan0.pid
lw-linkwatch once
! grep -q '^kill' "$EVENTS" || lw_fail "a signal went to a process that is not udhcpc: $(cat "$EVENTS")"
lw_expect_eq "$(ifups)" 1 "ifup wwan events without udhcpc"
rm -f /var/run/udhcpc-wwan0.pid
lk_lost
rm -f /tmp/lw-linkwatch/escalated
: >"$EVENTS"
lw-linkwatch once
! grep -q '^kill' "$EVENTS" || lw_fail "a signal without a pid file"

# PDP types: ipv6 and ipv4v6 are not restored in place, at once and without start-network
for t in ipv6 ipv4v6; do
    lk_setup
    uci set network.wwan.pdptype=$t
    uci commit network
    lk_lost
    lw-linkwatch once
    lw_expect_eq "$(cat "$EVENTS")" "ifup wwan" "events with pdptype $t"
    lw_expect_eq "$(lk_calls_of --start-network)" 0 "start-network calls with pdptype $t"
    lk_lines | grep -qF "data session lost, pdptype $t is not restored in place, ifup wwan" || lw_fail "info line: $(lk_lines)"
done
for t in ip IP ipv4 IPv4; do
    lk_setup
    uci set network.wwan.pdptype=$t
    uci commit network
    lk_lost
    lw-linkwatch once
    lw_expect_eq "$(lk_calls_of --start-network)" 1 "start-network calls with pdptype $t"
    lw_expect_eq "$(grep -c '^ifup' "$EVENTS" || true)" 0 "ifup events with pdptype $t"
done
echo ok
