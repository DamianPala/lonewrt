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

# lw_session KIND: what netifd says (tests/stubs/ifstatus) about the session of the interface wwan.
# The parent publishes the calls it made (data.cid_N and data.pdh_N, Terms "session"), the children
# have the leases and addresses.
#   legacy   status without published calls, as in the older fixtures: read as IPv4 on wwan0
#   v4       IPv4-only QMI call on wwan and DHCP on wwan_4, as on the current image
#   dual     v4 plus an IPv6 address and DNS server on wwan itself (the settings of qmi.sh, R73j)
#   v6       IPv6 only: wwan with the call, the address and DNS server, no wwan_4
#   v6clat   v6 plus the translation interface wwan_6_4 on its own device (R76, R76d)
#   v6child  IPv6 only through the child wwan_6 (the DHCPv6 way of R73j)
# The addresses are of the documentation ranges.
lw_session() {
    rm -f "$T/ifstatus/wwan.json" "$T/ifstatus/wwan_4.json" "$T/ifstatus/wwan_6.json" \
        "$T/ifstatus/wwan_6_4.json"
    _v4='"up":true,"l3_device":"wwan0","ipv4-address":[{"address":"192.0.2.10","mask":30}],"dns-server":["192.0.2.53"]'
    _a6='"ipv6-address":[{"address":"2001:db8:1::2","mask":128}],"dns-server":["2001:db8:53::1"]'
    _d4='"data":{"cid_4":"17","pdh_4":"3203210528"}'
    _d6='"data":{"cid_6":"18","pdh_6":"3203210530"}'
    case $1 in
        legacy)
            printf '{"up":true,"l3_device":"wwan0"}\n' >"$T/ifstatus/wwan.json"
            printf '{%s}\n' "$_v4" >"$T/ifstatus/wwan_4.json"
            ;;
        v4)
            printf '{"up":true,"l3_device":"wwan0",%s}\n' "$_d4" >"$T/ifstatus/wwan.json"
            printf '{%s}\n' "$_v4" >"$T/ifstatus/wwan_4.json"
            ;;
        dual)
            printf '{"up":true,"l3_device":"wwan0",%s,%s}\n' "$_a6" \
                '"data":{"cid_4":"17","pdh_4":"3203210528","cid_6":"18","pdh_6":"3203210530"}' \
                >"$T/ifstatus/wwan.json"
            printf '{%s}\n' "$_v4" >"$T/ifstatus/wwan_4.json"
            ;;
        v6 | v6clat)
            printf '{"up":true,"l3_device":"wwan0",%s,%s}\n' "$_a6" "$_d6" >"$T/ifstatus/wwan.json"
            [ "$1" = v6 ] || printf '{"up":true,"l3_device":"464-wwan_6_4","ipv4-address":[{"address":"192.0.0.1","mask":32}]}\n' \
                >"$T/ifstatus/wwan_6_4.json"
            ;;
        v6child)
            printf '{"up":true,"l3_device":"wwan0",%s}\n' "$_d6" >"$T/ifstatus/wwan.json"
            printf '{"up":true,"l3_device":"wwan0",%s}\n' "$_a6" >"$T/ifstatus/wwan_6.json"
            ;;
        *) lw_fail "lw_session: unknown kind '$1'" ;;
    esac
}

# lw_reach FAMILY DEVICE [TARGET [partial]]: from now on a ping of that family bound to that device
# (- for none, * for any) gets replies, as tests/stubs/ping describes; the first call turns that
# mode on, and lw_reach_none leaves it on with nothing answering. lw_reach_off goes back to the
# per-network mode of lw_net.
lw_reach() { echo "$1 $2 ${3:-*}${4:+ $4}" >>"$T/net/paths"; }
lw_reach_none() { : >"$T/net/paths"; }
lw_reach_off() { rm -f "$T/net/paths"; }

# lw_route DEST DEV: from now on `ip route get DEST` says the route leaves on DEV (tests/stubs/ip);
# the first call turns that mode on, lw_route_none leaves it on with nothing reachable, lw_route_off
# goes back to "everything leaves on wwan0".
lw_route() { echo "$1 $2" >>"$T/net/routes"; }
lw_route_none() { : >"$T/net/routes"; }
lw_route_off() { rm -f "$T/net/routes"; }

# lw_pings [PATTERN]: the number of pings the stub saw (all, or those matching the grep PATTERN).
lw_pings() {
    [ -f "$T/net-calls" ] || { echo 0; return 0; }
    grep -c -- "^ping .*${1:-}" "$T/net-calls" || :
}

# lw_at_override COMMAND CONTENT: per-command modem answer (HANG, SILENT or response lines).
lw_at_override() {
    printf '%s\n' "$2" >"$T/at/$(printf %s "$1" | tr -c 'A-Za-z0-9' _)"
}

lw_fail() { echo "FAIL: $*" >&2; exit 1; }
lw_expect_grep() { grep -q -- "$2" "$1" || lw_fail "no '$2' in $1"; }
lw_expect_no_grep() { ! grep -q -- "$2" "$1" || lw_fail "unexpected '$2' in $1"; }
lw_expect_eq() { [ "$1" = "$2" ] || lw_fail "${3:-value}: expected '$2', got '$1'"; }
