# Helpers for tests/watchcat/*.sh, sourced after /fw/tests/lib.sh. Not a test itself (no .sh suffix).
# shellcheck shell=sh disable=SC2034  # the variables are used by the tests that source this file
#
# The worker under test is the image's /usr/bin/watchcat.sh derived from the package, with the hook
# (tests/watchcat/derive.bash makes it, tests/rootfs/run.sh binds it at /wc-overlay), and next to it
# the package's own file as the stock side (/wc-stock). Both run here with the test clock instead of
# /proc/uptime (the one change made to either, the same in both), under the stand-ins of
# tests/watchcat/stubs: a `sleep` that moves the clock and ends the worker at $T/horizon, a `ping`
# that records its call and takes 10 s of that clock when it gets no answer, an `ifup` that records.

WCP=$T/wc-pings
WCE=$T/wc-events
WC_HOSTS='8.8.8.8 1.1.1.1'

# wc_setup: the world of lw_setup with an IPv4 session, the two workers under /tmp/wc, a stand-in
# for `/etc/init.d/watchcat start` (the worker calls it after a restart), nothing recorded yet
wc_setup() {
    lw_setup
    PATH=/fw/tests/watchcat/stubs:$PATH
    export PATH
    rm -rf "$T"/wc-* "$T/horizon" "$T/on-sleep" "$T/ping-hang" "$T/ping-fast" "$T/ubus-calls" "$T/started" "$T/ended" /tmp/lw-family /tmp/wc
    mkdir -p /tmp/wc
    for _wc_i in hook stock; do
        case $_wc_i in hook) _wc_src=/wc-overlay/usr/bin/watchcat.sh ;; *) _wc_src=/wc-stock/usr/bin/watchcat.sh ;; esac
        sed "s|/proc/uptime|$LW_UPTIME_FILE|g" "$_wc_src" >"/tmp/wc/$_wc_i.sh"
    done
    mkdir -p /etc/init.d
    printf '#!/bin/sh\necho "$(cut -d. -f1 "$LW_UPTIME_FILE") init $*" >>"$LW_TEST/wc-events"\n' >/etc/init.d/watchcat
    chmod +x /etc/init.d/watchcat
    : >"$WCP"
    : >"$WCE"
    lw_session v4
    lw_reach_none
}

# wc_run VARIANT HORIZON [PERIOD]: the worker of the entry wwan_soft as the init script starts it
# (restart_iface, the interface @wwan, pings every 60 s, reset of the timer after a restart), until
# the test clock reaches HORIZON. VARIANT is hook (the image's worker, with LW_WATCHCAT_FAMILY set as
# the init script sets it for the entry), plain (the same worker for any other entry: no variable) or
# stock (the package's own file).
wc_run() {
    echo "$2" >"$T/horizon"
    _wc_v=$1
    case $1 in plain) _wc_v=hook ;; esac
    # the stand-in sleep ends the worker with TERM at the horizon; the shell says so on stderr
    if [ "$1" = hook ]; then
        LW_WATCHCAT_FAMILY=1 sh "/tmp/wc/$_wc_v.sh" restart_iface "${3:-120}" "$WC_HOSTS" 60 standard @wwan null 0 ipv4 "" 1 2>>"$T/wc-stderr" || :
    else
        sh "/tmp/wc/$_wc_v.sh" restart_iface "${3:-120}" "$WC_HOSTS" 60 standard @wwan null 0 ipv4 "" 1 2>>"$T/wc-stderr" || :
    fi
}

# wc_now: the whole second of the test clock
wc_now() { cut -d. -f1 "$LW_UPTIME_FILE"; }

# wc_clock SECOND: set the test clock
wc_clock() { echo "$1.00 $1.00" >"$LW_UPTIME_FILE"; }

# wc_lines: the lines watchcat wrote to syslog, without the second and the process number
wc_lines() {
    grep ' watchcat\[' "$T/syslog" | sed 's/^[0-9]* watchcat\[[0-9]*\]: //' || :
}

# wc_ifups: the seconds of the restarts of wwan, one line each
wc_ifups() { sed -n 's/^\([0-9]*\) ifup wwan$/\1/p' "$WCE"; }

# wc_pings_of FAMILY: the pings that went out with that family flag, as recorded
wc_pings_of() { grep -- " ping -$1 " "$WCP" || :; }

# wc_uptime SECONDS: netifd says wwan has been up that long (the field the birth of a session is
# measured with, R14g)
wc_uptime() {
    sed -i "s/^{/{\"uptime\":$1,/" "$T/ifstatus/wwan.json"
}
