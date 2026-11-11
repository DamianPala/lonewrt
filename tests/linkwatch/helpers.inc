# Helpers for tests/linkwatch/*.sh, sourced after /fw/tests/lib.sh. Not a test itself (no .sh suffix).
# shellcheck shell=sh disable=SC2034  # the constants are used by the tests that source this file

LKS=$LW_TEST/syslog
CALLS=$LW_TEST/uqmi-calls
EVENTS=$LW_TEST/events
OLD_ADDR=10.1.2.3
NEW_ADDR=10.4.5.6
# the exact start-network call without options of network.wwan: the device is the control node of
# the test (a plain file, uqmi is a stand-in), client 17 comes from the netifd data below
START_PLAIN="-s -d /tmp/cdc-wdm0 -t 5000 --set-client-id wds,17 --start-network --autoconnect"
CLEAR_CALL="-s -d /tmp/cdc-wdm0 -t 3000 --set-client-id wds,17 --stop-network 0xffffffff --autoconnect"

# lk_setup: lw_setup, the stand-ins of this area first on PATH, netifd showing wwan up (client 17,
# handle 3203210528, device wwan0), a healthy session at the old address, a udhcpc process of the
# right name with netifd's pid file, a modem that is registered. The clock is the test clock; the
# stand-in sleep moves it. The signals to udhcpc go through the recording stand-in.
lk_setup() {
    lw_setup
    # a test may set the world up more than once: nothing of the earlier one stays
    rm -rf "$T/uqmi" "$T/addr" "$T/on-sleep" "$T/naps" "$T/syslog.prio" "$T/dhcp-deaf" "$T/release-delay" \
        "$T/release-never" "$T/release-replace" "$T/release-pending" "$T/iplooks" "$T/usr1-saw" "$T/usr1-sleeps" "$T/usr1-looks" /tmp/lw-linkwatch
    PATH=/fw/tests/linkwatch/stubs:$PATH
    export PATH LW_LINKWATCH_KILL=/fw/tests/linkwatch/stubs/lwkill LW_LINKWATCH_UQMI_LIMIT=2
    mkdir -p "$T/uqmi" "$T/addr" /var/run
    : >/tmp/cdc-wdm0
    uci set network.wwan.device=/tmp/cdc-wdm0
    uci set network.wwan.pdptype=ipv4
    for o in apn auth username password; do uci -q delete network.wwan.$o || :; done
    uci commit network
    lk_netifd up
    lk_healthy
    : >"$CALLS"
    : >"$T/sleeps"
    mkdir -p /tmp/fake
    printf '#!/bin/sh\nwhile :; do /bin/sleep 100; done\n' >/tmp/fake/udhcpc
    chmod +x /tmp/fake/udhcpc
    /tmp/fake/udhcpc &
    echo $! >/var/run/udhcpc-wwan0.pid
    echo bound >"$T/dhcp-state"
}

# lk_netifd up|down: what `ifstatus wwan` says
lk_netifd() {
    printf '{"up":%s,"l3_device":"wwan0","data":{"cid_4":"17","pdh_4":"3203210528"}}\n' \
        "$([ "$1" = up ] && echo true || echo false)" >"$T/ifstatus/wwan.json"
}

# lk_healthy / lk_lost: the modem's call is up at the old address, or lost while the device keeps
# that address (the failure of 2026-11-10)
lk_healthy() {
    echo up >"$T/uqmi/session"
    echo registered >"$T/uqmi/reg"
    echo $OLD_ADDR >"$T/uqmi/addr"
    echo $OLD_ADDR >"$T/addr/wwan0"
}
lk_lost() {
    lk_healthy
    echo down >"$T/uqmi/session"
}

# lk_info: the info lines of the watcher (the debug ones have the priority daemon.debug)
lk_info() { grep -c ' lw-linkwatch: ' "$LKS" || true; }
lk_lines() { grep ' lw-linkwatch: ' "$LKS" || true; }
lk_calls_of() { grep -c -e "$1" "$CALLS" || true; }
lk_debug_lines() { grep '^daemon.debug lw-linkwatch: ' "$T/syslog.prio" 2>/dev/null || true; }

# lk_expect_quiet: no uqmi call, no event, no syslog line from the watcher
lk_expect_quiet() {
    lw_expect_eq "$(cat "$CALLS")" "" "uqmi calls $1"
    lw_expect_eq "$(cat "$EVENTS")" "" "events $1"
    lw_expect_eq "$(lk_lines)" "" "watcher syslog lines $1"
}

# lk_no_action: nothing but reading happened: no start, no clear, no signal, no ifup, no log line
lk_no_action() {
    lw_expect_eq "$(lk_calls_of --start-network)$(lk_calls_of --stop-network)" 00 "start or clear calls $1"
    lw_expect_eq "$(cat "$EVENTS")" "" "events $1"
    lw_expect_eq "$(lk_info)" 0 "watcher syslog lines $1"
}
