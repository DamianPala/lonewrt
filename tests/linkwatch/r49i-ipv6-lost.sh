# R49i, R49a, R74f: with both calls published and IPv4 healthy, a lost IPv6 leaves the IPv4 call
# alone, with no `ifup wwan` or signal to udhcpc: the watcher reads the status
# of the IPv4 client and of the IPv6 client, confirms the loss with that client's settings once, and
# the LAN stops advertising IPv6 (tests/linkwatch/r74f-ipv6-call.sh has the rest). In an IPv6-only
# session it reads nothing at all.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc

V4D="-s -d /tmp/cdc-wdm0 -t 3000 --set-client-id wds,17 --get-data-status"
V6D="-s -d /tmp/cdc-wdm0 -t 3000 --set-client-id wds,18 --get-data-status"
V6S="-s -d /tmp/cdc-wdm0 -t 3000 --set-client-id wds,18 --get-current-settings"
for level in info debug; do
    lk_setup
    LW_LINKWATCH_LAN6=/fw/tests/linkwatch/stubs/lan6-init
    export LW_LINKWATCH_LAN6
    rm -f "$T/lan6-calls"
    lk_dual
    echo down >"$T/uqmi/session-18"
    uci set lonewrt.log=log
    uci set lonewrt.log.level=$level
    uci commit lonewrt
    : >"$CALLS"
    for _ in 1 2 3; do lw-linkwatch once; done
    lw_expect_eq "$(cat "$CALLS")" "$V4D
$V6D
$V6S
$V4D
$V6D
$V4D
$V6D" "calls with IPv6 lost ($level)"
    lw_expect_eq "$(wc -l <"$T/uqmi-calls.17" | tr -d ' ')" 3 "calls on the IPv4 client ($level)"
    lw_expect_eq "$(cat "$EVENTS")" "" "events ($level)"
    lw_expect_eq "$(lk_lines | wc -l | tr -d ' ')" 1 "watcher syslog lines ($level)"
    lw_expect_eq "$(wc -l <"$T/lan6-calls" | tr -d ' ')" 1 "one reload of the LAN ($level)"
done

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
lw_expect_eq "$(ls /var/run/lw-linkwatch 2>/dev/null)" "" "state of the watcher in an IPv6-only session"
echo ok
