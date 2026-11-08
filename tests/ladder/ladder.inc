# shellcheck shell=sh
# Shared setup for tests/ladder/*.sh (sourced; no .sh suffix, so run-all.sh does not run it).
# Every test runs wwan-recover and lw-fallback as installed in the rootfs sandbox; one "run" is one
# cron cycle, 5 min of uptime apart.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
PATH=/fw/tests/ladder/stubs:$PATH
export PATH
lw_setup

STATE=/etc/wwan-recover.state
SNAP=/root/wwan-recover-snapshot.txt
WR=/usr/sbin/wwan-recover
run=0
: >"$T/logread"
: >"$T/reboot-runs"
: >/root/openwrt.log

# boot_sim [UPTIME]: a reboot plus what the boot does in the other scripts (lw-modem-mode): LTE-only
# in uci and in the modem, an empty RAM log.
boot_sim() {
    lw_reboot_sim "${1:-60}"
    uci set network.wwan.modes=lte
    uci commit network
    echo 6,0,0 >"$T/modem/zsnt"
    : >"$T/logread"
}

# boot: the router rebooted; the next run is the first cron run after it, 5 min in (uptime 360),
# the same timing runs() uses after a reboot event.
boot() {
    boot_sim
    lw_uptime_add 300
}

# before_run: hook called before every run; tests redefine it (watchdog lines, network changes).
before_run() { :; }

# runs N: N cron runs 5 min apart; a reboot event makes the next run happen after boot_sim.
runs() {
    _i=0
    while [ "$_i" -lt "$1" ]; do
        _i=$((_i + 1))
        run=$((run + 1))
        before_run
        _ev=$(wc -l <"$T/events")
        "$WR" >>"$T/out" 2>&1 || lw_fail "wwan-recover exited $? in run $run"
        if tail -n +$((_ev + 1)) "$T/events" | grep -q '^reboot'; then
            echo "$run" >>"$T/reboot-runs"
            boot_sim
        fi
        lw_uptime_add 300
    done
}

# state_set KEY=VALUE...: write a recovery state file as a previous image run would have left it.
state_set() {
    printf '%s\n' "$@" >"$STATE"
}

state_get() { sed -n "s/^$1=//p" "$STATE"; }

# wr_at PATTERN: the cycle= values of the wwan-recover syslog lines matching PATTERN, space-joined.
wr_at() {
    grep "wwan-recover: $1" "$T/syslog" | sed 's/.* cycle=\([0-9]*\) .*/\1/' | tr '\n' ' ' |
        sed 's/ $//'
}

reboot_runs() { tr '\n' ' ' <"$T/reboot-runs" | sed 's/ $//'; }

count() { grep -c -- "$1" "$2" || true; }

mode_now() { /usr/sbin/lw-fallback mode; }

# check_format: every wwan-recover line ends with the R21e fields; syslog, snapshot and state are
# plain ASCII (R29b); the state has the R21d keys.
check_format() {
    _bad=$(grep 'wwan-recover: ' "$T/syslog" | grep -v -E \
        ' cycle=[0-9]+ reboots=[0-9]+ class=(none|sim|account|hang|unknown) mode=(lte|edge) uptime=[0-9]+$' ||
        true)
    [ -z "$_bad" ] || lw_fail "wwan-recover lines without the R21e tail: $_bad"
    for _f in "$T/syslog" "$SNAP" "$STATE"; do
        [ -f "$_f" ] || continue
        [ "$(tr -d '\011\012\040-\176' <"$_f" | wc -c)" = 0 ] || lw_fail "non-ASCII bytes in $_f"
    done
    if [ -f "$STATE" ]; then
        lw_expect_eq "$(cut -d= -f1 "$STATE" | tr '\n' ' ')" "cycles reboots class passive uptime " \
            "state keys"
    fi
    return 0
}
