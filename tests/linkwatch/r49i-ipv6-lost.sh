# R49i, R49a: with both calls published and IPv4 healthy, a lost IPv6 never leads to a call for it, a
# stop of the IPv4 call, an `ifup wwan` or any line: the watcher reads the status of the IPv4
# client and nothing else, pass after pass. In an IPv6-only session it reads nothing at all.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc

lk_setup
lk_dual
echo down >"$T/uqmi/session-18"
for level in info debug; do
    uci set lonewrt.log=log
    uci set lonewrt.log.level=$level
    uci commit lonewrt
    : >"$CALLS"
    for i in 1 2 3; do lw-linkwatch once; done
    lw_expect_eq "$(cat "$CALLS")" "-s -d /tmp/cdc-wdm0 -t 3000 --set-client-id wds,17 --get-data-status
-s -d /tmp/cdc-wdm0 -t 3000 --set-client-id wds,17 --get-data-status
-s -d /tmp/cdc-wdm0 -t 3000 --set-client-id wds,17 --get-data-status" "calls with IPv6 lost ($level)"
    lw_expect_eq "$(cat "$T/uqmi-calls.18" 2>/dev/null)" "" "calls on the IPv6 client ($level)"
    lw_expect_eq "$(cat "$EVENTS")" "" "events ($level)"
    lw_expect_eq "$(lk_lines)" "" "watcher syslog lines ($level)"
done
[ ! -e /tmp/lw-linkwatch ] || lw_fail "state written while IPv4 was healthy"

# the IPv6 call vanishes from netifd's data while IPv4 stays: still only the IPv4 status
lk_netifd up v4
: >"$CALLS"
lw-linkwatch once
lw_expect_eq "$(wc -l <"$CALLS" | tr -d ' ')" 1 "calls after the IPv6 call left netifd's data"

# an IPv6-only session: not one call, with the call alive or lost, over many passes
lk_setup
lk_netifd up v6
echo up >"$T/uqmi/session-18"
LW_LINKWATCH_PASSES=12 lw-linkwatch run
lk_expect_quiet "in an IPv6-only session"
echo down >"$T/uqmi/session-18"
LW_LINKWATCH_PASSES=12 lw-linkwatch run
lk_expect_quiet "in an IPv6-only session that lost its call"
lw_expect_eq "$(ls /tmp/lw-linkwatch 2>/dev/null)" "" "state of the watcher in an IPv6-only session"
echo ok
