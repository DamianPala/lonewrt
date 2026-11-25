#!/usr/bin/env bash
# Helpers of the scenarios that run the router against the operator stand-in tests/vm/nat64-peer.py:
# 95-clat.sh and 96-clat-verify.sh (sourced after lib.sh, bash). The peer is the other end of the router's
# wwan NIC, the stand-in protocol `lwvm` of tests/vm/overlay gives wwan its sessions; this file has what both
# scenarios do the same way: start and stop the peer, switch it with files, set a session, and say what
# is true in the router (the translation up, nothing of it left, one helper and one set of rules).
# shellcheck disable=SC2016,SC2119 # guest scripts expand in the guest; helper args are optional
# shellcheck disable=SC2034 # PFX and PEER_PID are read by the scenarios

# an operator's prefix: global, not the well-known one and not a documentation range of 2001:db8
# (dnsmasq drops answers in 2001:db8 as a possible rebind attack, README.md of tests/vm)
PFX=3fff:64:6464::/96
PEER_PID=

peer_stop() {
    [ -z "$PEER_PID" ] || { kill "$PEER_PID" 2>/dev/null || true; wait "$PEER_PID" 2>/dev/null || true; }
    PEER_PID=
}

# plog PATTERN: how many lines of the peer's log match (a basic regular expression)
plog() { grep -c -- "$1" "$RUN/peer/peer.log" || true; }
# pset FILE VALUE: a switch of the peer (dns64, nat64, ra: on|off|drop; prefix, ra-prefix, mtu, ingress, ptb, udp-forward)
pset() { echo "$2" >"$RUN/peer/$1"; }

peer_start() {
    mkdir -p "$RUN/peer"
    : >"$RUN/peer/peer.log"
    python3 -I "$VMDIR/nat64-peer.py" --sock "$RUN/wwan.sock" --ctl "$RUN/peer" --log "$RUN/peer/peer.log" \
        --prefix "$PFX" >"$RUN/peer/peer.out" 2>&1 &
    PEER_PID=$!
    for _ in $(seq 50); do
        [ -S "$RUN/wwan.sock" ] && return 0
        sleep 0.1
    done
    return 1
}

# wwan_mode v4|v6|dual|dualchild: the stand-in protocol's session, applied by a reload of the network
wwan_mode() {
    vm_sh "uci set network.wwan.mode='$1'; uci commit network; /etc/init.d/network reload" 60 >/dev/null
}

# new_session: the same session again, from nothing (what a restart of wwan does)
new_session() {
    vm_sh 'ifdown wwan; sleep 2; ifup wwan' 60 >/dev/null
}

# PING_OK: the first packets after a translation is up may be lost (nat46 meets its first IPv4 packet,
# found with the host's CPUs busy: the pings 1 s apart lost 1 and 2, then went through, while the
# interface had been up since before; TCP and later pings never failed). It is the bench, not the
# translation: netifd and the helper are right, and a ping that is retried for a bounded time (8 tries, 2 s
# each) answers. How many were lost goes to /tmp/clat-first-lost, shown at the end, so the rate stays visible.
PING_OK='i=0; until ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; do i=$((i + 1)); [ $i -lt 8 ] || exit 1; done; echo "$i lost before the first reply" >>/tmp/clat-first-lost'

# ---- what is true in the router ------------------------------------------------------------------

# wwan_up: wwan is up, the way ifup of the hotplug saw it
wwan_up() { vm_wait_for 'ubus call network.interface.wwan status | jsonfilter -e "@.up" | grep -qx true' 60; }

# child_up: the IPv6 child has its address and default route from the advertisements, and the DNS
# server from the RDNSS option of them. The first argument is the /64 of the link (default: the first one)
child_up() {
    vm_wait_for 's=$(ubus call network.interface.wwan_6 status) &&
        [ "$(echo "$s" | jsonfilter -e "@.up")" = true ] &&
        echo "$s" | jsonfilter -e "@[\"dns-server\"][*]" | grep -qx 2001:db8:64::53 &&
        echo "$s" | jsonfilter -e "@[\"ipv6-address\"][*].address" | grep -q "^'"${1:-2001:db8:64:100:}"'"' 90
}

# translated: the translation interface is up on its device, one helper holds its address
translated() {
    vm_wait_for '[ "$(ubus call network.interface.wwan_6_4 status | jsonfilter -e "@.up")" = true ] &&
        [ "$(ubus call network.interface.wwan_6_4 status | jsonfilter -e "@.l3_device")" = 464-wwan_6_4 ]' "${1:-90}"
}

# no_translation: nothing of a translation exists: no interface, no helper, no device, no marker
no_translation() {
    vm_sh '! ubus call network.interface.wwan_6_4 status >/dev/null 2>&1 &&
        [ "$(ps w | grep -c "[4]64xlatcfg")" = 0 ] &&
        [ ! -e /sys/class/net/464-wwan_6_4 ] && ! ls /tmp/464-*-anycast >/dev/null 2>&1 &&
        [ ! -e /var/run/lw-clat/active ] && [ "$(ip -6 rule | grep -c "from all lookup local")" = 1 ] &&
        [ "$(ip -6 rule | grep -c prelocal)" = 0 ]' 30
}

# one_translation: one helper that its pid file names, one device, one set of rules (no leftovers of a
# helper that died or of a setup that failed)
one_translation() {
    vm_sh '[ "$(ps w | grep -c "[4]64xlatcfg")" = 1 ] && [ "$(ip -o link show | grep -c " 464-wwan_6_4")" = 1 ] &&
        grep -qa 464xlatcfg "/proc/$(cat /var/run/464-wwan_6_4.pid)/cmdline" &&
        [ "$(ip -6 rule | grep -c "lookup prelocal")" = 1 ] && [ "$(ip -6 rule | grep -c "from all lookup local")" = 1 ] &&
        [ "$(ls /tmp/464-*-anycast | wc -l)" = 1 ]' 30
}

# clat_lines: the lines the check wrote to the log
clat_lines() { vm_sh 'logread | grep -c "lw-clat" || true' | tr -d '\r'; }
