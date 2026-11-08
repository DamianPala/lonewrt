# Test helpers, sourced by tests/<area>/*.sh inside the rootfs sandbox (tests/rootfs/run.sh).
# State the stubs read and write lives in $LW_TEST (/lwtest); see tests/stubs/* for each knob.
set -eu

T=$LW_TEST

# lw_setup: install the image's files over the rootfs and give the stubs a clean world:
# LTE down, EDGE down, DNS silent, modem answering with ZSNT 6, uptime 1000 s.
lw_setup() {
    mkdir -p "$T/net" "$T/dns" "$T/at" "$T/modem/sms" "$T/stats" "$T/ifstatus" /root
    cp -a /fw/src/files/. /
    for f in tx_packets rx_packets tx_errors tx_dropped rx_dropped; do echo 0 >"$T/stats/$f"; done
    echo 6,0,0 >"$T/modem/zsnt"
    echo 1000.00 1000.00 >"$T/uptime"
    : >"$T/syslog"
    : >"$T/events"
    touch /etc/config/network
    uci -q batch <<'UCI'
set network.wwan=interface
set network.wwan.proto=qmi
set network.wwan.device=/dev/cdc-wdm0
set network.wwan.modes=lte
commit network
UCI
    printf '{"up":true,"dns-server":["192.0.2.53"]}\n' >"$T/ifstatus/wwan_4.json"
}

# lw_uptime_set SECONDS / lw_uptime_add SECONDS: move the clock the scripts read.
lw_uptime_set() { echo "$1.00 $1.00" >"$T/uptime"; }
lw_uptime_add() { lw_uptime_set $(($(cut -d. -f1 "$T/uptime") + $1)); }

# lw_reboot_sim [UPTIME]: what a reboot does to the state the scripts see: /tmp is empty, uptime
# starts again (default 60 s), the modem keeps its NVRAM, /etc and /root stay.
lw_reboot_sim() {
    find /tmp -mindepth 1 -maxdepth 1 -exec rm -r {} +
    lw_uptime_set "${1:-60}"
}

# lw_net LTE EDGE / lw_dns LTE EDGE: up or down per network.
lw_net() { echo "$1" >"$T/net/lte"; echo "$2" >"$T/net/edge"; }
lw_dns() { echo "$1" >"$T/dns/lte"; echo "$2" >"$T/dns/edge"; }

# lw_at_override COMMAND CONTENT: per-command modem answer (HANG, SILENT or response lines).
lw_at_override() {
    printf '%s\n' "$2" >"$T/at/$(printf %s "$1" | tr -c 'A-Za-z0-9' _)"
}

lw_fail() { echo "FAIL: $*" >&2; exit 1; }
lw_expect_grep() { grep -q -- "$2" "$1" || lw_fail "no '$2' in $1"; }
lw_expect_no_grep() { ! grep -q -- "$2" "$1" || lw_fail "unexpected '$2' in $1"; }
lw_expect_eq() { [ "$1" = "$2" ] || lw_fail "${3:-value}: expected '$2', got '$1'"; }
