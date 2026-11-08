# Helpers for tests/modem/*.sh, sourced after /fw/tests/lib.sh. Not a test itself (no .sh suffix).
# shellcheck shell=sh

# modem_setup [BANDS]: lw_setup, the modem tests' stubs first on PATH, lonewrt.modem.bands set (empty =
# option absent) and the image's delays shortened.
modem_setup() {
    lw_setup
    PATH=/fw/tests/modem/stubs:$PATH
    : >/etc/config/lonewrt
    uci -q set lonewrt.modem=modem
    [ -z "${1:-}" ] || uci -q set lonewrt.modem.bands="$1"
    uci -q commit lonewrt
    : >"$T/at-calls"
    export PATH LW_MODEM_SETTLE=1 LW_MODEM_RETRY=1 LW_MODEM_PORT_WAIT=4 LW_APN_IMSI_DELAY=1
}

# wait_gone PATTERN SECONDS: until no process command line matches PATTERN; fails after SECONDS.
wait_gone() {
    _i=0
    while pgrep -f "$1" >/dev/null; do
        [ "$_i" -lt "$2" ] || lw_fail "'$1' still running after $2 s"
        sleep 1
        _i=$((_i + 1))
    done
}

# wait_log TEXT SECONDS: until the syslog has TEXT; fails after SECONDS.
wait_log() {
    _i=0
    until grep -q -- "$1" "$T/syslog"; do
        [ "$_i" -lt "$2" ] || { cat "$T/syslog" >&2; lw_fail "no '$1' in syslog after $2 s"; }
        sleep 1
        _i=$((_i + 1))
    done
}

# count FILE TEXT: lines of FILE with TEXT (0 when FILE is missing).
count() {
    if [ -f "$1" ]; then grep -c -F -- "$2" "$1" || :; else echo 0; fi
}

# njson DIR: number of *.json files in DIR (0 when DIR is missing).
njson() {
    if [ -d "$1" ]; then find "$1" -maxdepth 1 -type f -name '*.json' | wc -l; else echo 0; fi
}

# hotplug ACTION: the netifd event for wwan, as hotplug-call runs it; fails when it does not return
# within a second (R13d).
hotplug() {
    _t0=$(date +%s)
    ACTION=$1 INTERFACE=wwan sh /etc/hotplug.d/iface/99-auto-apn-at
    [ $(($(date +%s) - _t0)) -le 1 ] || lw_fail "hotplug $1 did not return at once"
}

# apn_event ACTION: one hotplug event and the wait for its background worker.
apn_event() {
    hotplug "$1"
    sleep 1
    wait_gone 'usr/lib/lw/lw-apn' "${2:-30}"
}

# no_orphans: no AT helper left running (R12b).
no_orphans() {
    ! pgrep -f 'sms_tool|flock /tmp/lw-at.lock' >/dev/null || {
        ps >&2
        lw_fail "orphaned AT process"
    }
}
