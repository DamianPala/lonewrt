#!/bin/sh
# VM test bench only, never in a router image (tests/vm/95-clat.sh). A stand-in for the end of qmi.sh
# that matters to the CLAT: what the real protocol tells netifd after a data call, without a modem.
# The data of the interface carry the handles of the calls (cid_4/pdh_4 for an IPv4 call, cid_6/pdh_6
# for an IPv6 call, as qmi.sh sends them), and the IPv6 settings go the way qmi.sh sends them
# (R73j, D186): an IPv6-only session always takes them from the link through the DHCPv6 child
# wwan_6 (the same JSON qmi.sh gives add_dynamic: iface_464xlat 0, extendprefix 1), so odhcp6c runs
# on the NIC and gets its address, default route and DNS server from the operator's router
# advertisements; a dual-stack session takes the report of the modem, the settings of the operator
# fixed here the way the peer of the bench (tests/vm/nat64-peer.py) has them.
#
#   option mode  v6    an IPv6 call only (the case of 464XLAT)
#                v4    an IPv4 call only (the owner's SIM)
#                dual  both calls, native IPv4 and IPv6 from the modem's report (static)
#                dualchild  both calls, the IPv6 settings from the link through wwan_6 (dhcpv6=1, or a
#                      report that could not be used), as qmi.sh does for a session with native IPv4
#
# The record of the session kind is what qmi.sh's lw_clat_mark writes when it makes the child:
# the handles of an IPv6-only call and the uptime of the setup, removed in a session with an IPv4
# call (qmi-edits/functions.sh). The bench does not run qmi.sh, so the same lines are here.

# shellcheck disable=SC1091,SC2034,SC3043 # netifd's shell protocol API: busybox ash, variables it reads
[ -n "$INCLUDE_ONLY" ] || {
    . /lib/functions.sh
    . ../netifd-proto.sh
    init_proto "$@"
}

proto_lwvm_init_config() {
    available=1
    no_device=1
    proto_config_add_string "device"
    proto_config_add_string "mode"
    proto_config_add_defaults
}

proto_lwvm_setup() {
    local interface="$1" device mode d up
    json_get_vars device mode
    mode=${mode:-v6}

    echo "Setting up $device ($mode)"
    proto_init_update "$device" 1
    proto_set_keep 1
    proto_add_data
    case $mode in v4 | dual | dualchild)
        json_add_string cid_4 16
        json_add_string pdh_4 17
        ;;
    esac
    case $mode in v6 | dual | dualchild)
        json_add_string cid_6 18
        json_add_string pdh_6 19
        ;;
    esac
    proto_close_data
    proto_send_update "$interface"

    case $mode in v6 | dualchild)
        d=${LW_CLAT_DIR:-/var/run/lw-clat}
        if [ "$mode" = v6 ]; then
            read -r up _ </proc/uptime
            mkdir -p "$d" && echo "18/19/$up" >"$d/v6only"
        elif [ -s "$d/v6only" ]; then
            : >"$d/v6only"
        fi
        ;;
    esac
    case $mode in
    v6 | dualchild)
        json_init
        json_add_string name "${interface}_6"
        json_add_string ifname "@$interface"
        json_add_string iface_464xlat "0"
        json_add_string proto "dhcpv6"
        proto_add_dynamic_defaults
        json_add_string extendprefix 1
        json_close_object
        ubus call network add_dynamic "$(json_dump)"
        ;;
    dual)
        proto_init_update "$device" 1
        proto_set_keep 1
        proto_add_ipv6_address 2001:db8:64:100::2 128
        proto_add_ipv6_prefix 2001:db8:64:100::2/64
        proto_add_ipv6_route 2001:db8:64::1 128
        proto_add_ipv6_route "::0" 0 2001:db8:64::1 "" "" 2001:db8:64:100::2/64
        proto_add_dns_server 2001:db8:64::53
        proto_send_update "$interface"
        ;;
    esac
    case $mode in v4 | dual | dualchild)
        proto_init_update "$device" 1
        proto_set_keep 1
        proto_add_ipv4_address 10.0.3.15 255.255.255.0
        proto_add_ipv4_route 10.0.3.2 32
        proto_add_ipv4_route 0.0.0.0 0 10.0.3.2
        proto_add_dns_server 10.0.3.3
        proto_send_update "$interface"
        ;;
    esac
}

proto_lwvm_teardown() {
    proto_init_update "*" 0
    proto_send_update "$1"
}

[ -n "$INCLUDE_ONLY" ] || {
    add_protocol lwvm
}
