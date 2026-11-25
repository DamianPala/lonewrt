#!/usr/bin/env bash
# IPv4 over an IPv6-only session with the real stock 464xlat and kmod-nat46 (SPEC R76 to R76e, R77,
# D169, D186, and what the SPEC marks unverified about the stock protocol, the helper 464xlatcfg and
# the module; and what the review of slice C1 found: nothing starts on an IPv4-only or dual-stack
# session, the end of a session cleans up, a new session with the same handles gets its own
# translation, a diverted route to the DNS64 server is refused). Two guests: the router (the image of the current render, the stand-in protocol `lwvm`
# of tests/vm/overlay in place of qmi: the data of the call, and for an IPv6-only session the same
# DHCPv6 child wwan_6 that qmi.sh makes) and the small LAN guest of 80-tailscale.sh. The operator is
# tests/vm/nat64-peer.py on the host, the other end of the router's wwan NIC: router advertisements
# with a /64 and an RDNSS option (so odhcp6c of wwan_6 runs for real), a DNS64, and a NAT64 that
# answers pings and TCP connections.
#
#   tests/vm/95-clat.sh
#
# The IPv4 of the guests never leaves the host: the NAT64 is the peer, a connection to 8.8.8.8 is
# answered by the program, and nothing is sent to a real address. The NAT64 prefix is not the
# well-known one (a prefix of an operator is not), so dnsmasq's rebind protection is part of what
# runs: the LAN client resolves names through the router's own dnsmasq.
# shellcheck disable=SC2016,SC2119 # guest scripts expand in the guest; helper args are optional
# shellcheck disable=SC2153 # PFX comes from clat-lib.sh
# shellcheck disable=SC2329 # scenarios pass callbacks to must/check and the EXIT trap
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=clat-lib.sh
. "$VMDIR/clat-lib.sh"
SCENARIO=clat

LGRUN=$VMWORK/run/$SCENARIO-lan
IMG_LG=
IMG_RT=

cl_cleanup() {
    if [ -d "$LGRUN" ]; then vm_py stop --run "$LGRUN" || true; fi
    vm_cleanup
    peer_stop
}
trap cl_cleanup EXIT

lg_sh() { RUN=$LGRUN vm_sh "$@"; }
lg_check() { check "$1" lg_sh "$2" "${3:-60}"; }

# ---- images ----------------------------------------------------------------------------------------

build_images() {
    mkdir -p "$VMWORK/logs"
    IMG_RT=$(LWVM_NO_CURRENT=1 "$VMDIR/build-image.sh" 2>"$VMWORK/logs/clat-image.log" | tail -n1) || true
    IMG_LG=$("$VMDIR/build-lan-guest.sh" 2>"$VMWORK/logs/clat-image-lan-guest.log" | tail -n1) || true
    [ -f "$IMG_RT/disk.img" ] && [ -f "$IMG_LG/disk.img" ]
}

# lan_prepare: br-lan gets the LAN guest's NIC (eth2) in place of the harness's user-net NIC (as in
# 80-tailscale.sh: its own DHCP server would make dnsmasq refuse to serve the LAN)
lan_prepare() {
    vm_sh 's=$(uci show network | sed -n "s/^network\.\(@device\[[0-9]*\]\)\.name=.br-lan.\$/\1/p" | head -n1)
[ -n "$s" ] || exit 1
uci set "network.$s.ports=eth2"; uci commit network
/etc/init.d/network reload; /etc/init.d/dnsmasq restart' 60 >/dev/null &&
        vm_wait_for '[ "$(ls /sys/class/net/br-lan/brif)" = eth2 ] && netstat -lnu | grep -q ":67 "' 60
}

lg_start() {
    rm -rf "$LGRUN"
    mkdir -p "$LGRUN"
    cp --reflink=auto "$IMG_LG/disk.img" "$LGRUN/disk.img"
    vm_py start --run "$LGRUN" --guest --link-role client --link-sock "$RUN/lanlink.sock" \
        >>"$LGRUN/harness.log"
    RUN=$LGRUN vm_wait_ready 120
}

# rec_on / rec_off: the check of the image is replaced by a recorder that writes its arguments to
# /tmp/clat-calls, and back: a start of the check by the hotplug dispatch or by wwan-recover shows
rec_on() {
    vm_sh 'cp /usr/sbin/lw-clat-check /root/lw-clat-check.real
{ echo "#!/bin/sh"; echo "echo \"\$*\" >>/tmp/clat-calls"; } >/usr/sbin/lw-clat-check
chmod 755 /usr/sbin/lw-clat-check; : >/tmp/clat-calls' 30
}
rec_off() {
    vm_sh 'cp /root/lw-clat-check.real /usr/sbin/lw-clat-check; chmod 755 /usr/sbin/lw-clat-check; rm -f /tmp/clat-calls' 30
}
# never_started: the check was not started, and left nothing: no call, no state directory, no line
never_started() {
    vm_sh '[ ! -s /tmp/clat-calls ] && [ ! -e /var/run/lw-clat/active ] && [ ! -e /var/run/lw-clat/lock ] &&
        [ "$(logread | grep -c "lw-clat")" = 0 ]' 30
}

# the DNS queries to the session's server, counted per output device (R76a: the query has to leave on
# the child's device): count_on makes the counters, count_check says where the packets went
# only the question of the check: AAAA for ipv4only.arpa is a 79-byte packet; the router's other lookups (the ladder's probes, dnsmasq) have
# other names and lengths, and they may use the default route that the scenario puts over br-lan
DNSQ='ip6 daddr 2001:db8:64::53 udp dport 53 meta length 79'
count_on() {
    vm_sh "nft delete table inet c1count 2>/dev/null; nft add table inet c1count
nft 'add chain inet c1count out { type filter hook output priority -300; policy accept; }'
nft add rule inet c1count out $DNSQ oifname wwan0 counter
nft add rule inet c1count out $DNSQ oifname br-lan counter" 30
}
count_check() {
    vm_sh 'nft list chain inet c1count out | grep -q "oifname \"wwan0\" counter packets [1-9]" &&
     nft list chain inet c1count out | grep -q "oifname \"br-lan\" counter packets 0 "' 30
}

# ---- the scenario ----------------------------------------------------------------------------------

build_images || { echo "  FAIL  images build (see $VMWORK/logs/clat-image*.log)"; exit 1; }
echo "  ok    images build (router: the render of this tree, LAN guest)"
# shellcheck disable=SC2034 # read by vm_init in lib.sh
IMAGE=$IMG_RT
vm_init
peer_start || { echo "  FAIL  the operator stand-in does not listen"; exit 1; }
echo "  ok    the operator stand-in listens"
vm_start --link-role server --link-sock "$RUN/lanlink.sock" --wwan-peer "$RUN/wwan.sock"
must "router boots to the end of its init scripts" vm_wait_ready
note "packages: $(grep -E '^(464xlat|kmod-nat46) ' "$IMG_RT/manifest" | tr '\n' ' ')"
must "br-lan has the LAN guest's NIC, dnsmasq serves DHCP" lan_prepare
# the bench's stand-in for 8.8.8.8 and 1.1.1.1 (the user-net gateway) would answer instead of the NAT64
must "the bench's DNAT of the two ping targets is out of the way" vm_sh 'nft delete table ip lwvm'
gcheck "kernel module nat46 loads and the stock protocol and helper are in the image (R76e)" \
    'modprobe nat46 2>&1; [ -e /proc/net/nat46/control ] && [ -x /lib/netifd/proto/464xlat.sh ] && [ -x /sbin/464xlatcfg ]'
gcheck "the image's qmi.sh switches the stock 464XLAT interface off (D186)" \
    'grep -q "json_add_string iface_464xlat .0." /lib/netifd/proto/qmi.sh'
must "the stand-in protocol replaces qmi on wwan" vm_sh \
    'uci set network.wwan.proto=lwvm; uci -q delete network.lwvm_default; uci set network.wwan.mode=v4; uci commit network
/etc/init.d/network reload' 60

# ---- the owner's path: an IPv4 session ---------------------------------------------------------------
echo "# IPv4 session (the owner's SIM)"
must "the check is replaced by a recorder for the sessions that must not start it" rec_on
must "wwan is up with an IPv4 call" wwan_up
gcheck "the data of wwan have the IPv4 call and no IPv6 call" \
    'ubus call network.interface.wwan status | jsonfilter -e "@.data.cid_4" -e "@.data.cid_6" | grep -qx 16 &&
     [ -z "$(ubus call network.interface.wwan status | jsonfilter -e "@.data.cid_6")" ]'
sleep 12
# the check starts only for wwan_6 and, while a translation exists, for wwan: an IPv4-only router
# never has either, so nothing of it ever ran: not its directory, not its lock, not one line
gcheck "R76b: the IPv4-only router never started the check (no call, no state directory, no line)" \
    '[ ! -e /var/run/lw-clat ] && [ ! -s /tmp/clat-calls ] && [ "$(logread | grep -c "lw-clat")" = 0 ] && ! pgrep -f lw-clat-check >/dev/null'
check "R76b: no DNS64 query went out" test "$(plog 'dns AAAA ipv4only.arpa')" = 0
gcheck "R76b: no interface wwan_6_4, no 464xlatcfg, no nat46 device, no IPv6 child" \
    '! ubus call network.interface.wwan_6_4 status >/dev/null 2>&1 && [ "$(ps w | grep -c "[4]64xlatcfg")" = 0 ] &&
     [ ! -e /sys/class/net/464-wwan_6_4 ] && ! ubus call network.interface.wwan_6 status >/dev/null 2>&1'
# the ladder of an IPv4-only session runs nothing for the translation either
gcheck "R76c: a run of wwan-recover on the IPv4-only session leaves the same state" \
    '/usr/sbin/wwan-recover; [ ! -e /var/run/lw-clat ] && [ ! -s /tmp/clat-calls ] && [ "$(logread | grep -c "lw-clat")" = 0 ]' 120

# ---- a dual-stack session: native IPv4, no translation ---------------------------------------------
echo "# dual-stack session"
must "dual-stack session" wwan_mode dual
must "wwan is up with both calls" wwan_up
gcheck "both calls in the data of wwan" \
    '[ "$(ubus call network.interface.wwan status | jsonfilter -e "@.data.cid_4" -e "@.data.cid_6" | wc -l)" = 2 ]'
sleep 12
check "R76b: no DNS64 query in a dual-stack session" test "$(plog 'dns AAAA ipv4only.arpa')" = 0
check "R76b: no translation in a dual-stack session" no_translation
check "R76b: the dual-stack session never started the check" never_started
gcheck "R76c: a run of wwan-recover on the dual-stack session leaves the same state" \
    '/usr/sbin/wwan-recover; [ ! -e /var/run/lw-clat ] && [ ! -s /tmp/clat-calls ] && [ "$(logread | grep -c "lw-clat")" = 0 ]' 120

# ---- a dual-stack session whose IPv6 settings come from the link: an IPv6 child, native IPv4 -------------
echo "# dual-stack session with an IPv6 child (dhcpv6=1, or a report that could not be used)"
must "dual-stack session, IPv6 through the child" wwan_mode dualchild
must "wwan is up with both calls" wwan_up
must "wwan_6 runs odhcp6c" child_up
sleep 12
gcheck "R76b: the child is up beside native IPv4, with no IPv6-only session recorded" \
    '[ "$(ubus call network.interface.wwan_6 status | jsonfilter -e "@.proto")" = dhcpv6 ] && [ ! -s /var/run/lw-clat/v6only ] &&
     [ -n "$(ubus call network.interface.wwan status | jsonfilter -e "@.data.cid_4")" ]'
check "R76b: the child's ifup started nothing: no call of the check, no state, no line" never_started
check "R76b: no DNS64 query" test "$(plog 'dns AAAA ipv4only.arpa')" = 0
check "R76b: no translation" no_translation
must "the same session again: the child comes up once more" new_session
must "wwan_6 is up again" child_up
gcheck "R76b: the child's ifup again starts nothing either" \
    'sleep 8; [ ! -s /tmp/clat-calls ] && [ ! -e /var/run/lw-clat/active ] && [ "$(logread | grep -c "lw-clat")" = 0 ]' 90
gcheck "R76c: a run of wwan-recover on this session starts nothing" \
    '/usr/sbin/wwan-recover; [ ! -s /tmp/clat-calls ] && [ "$(logread | grep -c "lw-clat")" = 0 ]' 120
must "the check of the image is back" rec_off

# ---- the IPv6-only session ---------------------------------------------------------------------------
echo "# IPv6-only session"
must "counters for the DNS queries, per device" count_on
must "IPv6-only session" wwan_mode v6
must "wwan is up with an IPv6 call" wwan_up
must "wwan_6 runs odhcp6c: address and default route from the advertisements, DNS from the RDNSS option" child_up
gcheck "R76b: qmi.sh's record of the session: the handles of the call and the uptime of its setup" \
    '[ "$(sed "s|/[^/]*\$||" /var/run/lw-clat/v6only)" = 18/19 ]'
gcheck "R76: wwan has no IPv4 call, no IPv4 address; the IPv6 child is the stock DHCPv6 protocol" \
    '[ -z "$(ubus call network.interface.wwan status | jsonfilter -e "@.data.cid_4")" ] &&
     [ "$(ubus call network.interface.wwan_6 status | jsonfilter -e "@.proto")" = dhcpv6 ] && pgrep odhcp6c >/dev/null'
translated || gnote 'logread | grep -E "lw-clat|464xlat|netifd|odhcp6c" | tail -n 40; ubus list | grep wwan; ubus call network.interface.wwan_6 status; ls -la /var/run/lw-clat; ps w | grep -E "lw-clat|464"; ip -6 addr; ip -6 route; cat /etc/resolv.conf /tmp/resolv.conf.d/* 2>/dev/null'
must "the translation comes up on 464-wwan_6_4 (R76d)" translated
gnote 'logread | grep -E "lw-clat|464xlat"; ubus call network.interface.wwan_6_4 status | head -n 40; ip -4 addr show 464-wwan_6_4; ip -4 route; ip -6 rule; cat /proc/net/nat46/control; ip link show 464-wwan_6_4 | head -n 1'
gcheck "D186: one interface wwan_6_4 and the stock DHCPv6 script did not make it (iface_464xlat 0)" \
    '[ "$(ubus list | grep -c "^network.interface.wwan_6_4$")" = 1 ] &&
     [ "$(ubus call network.interface.wwan_6 status | jsonfilter -e "@.data.iface_464xlat")" != 1 ]'
check "R76a: the prefix was asked of the operator's DNS64, once, and by nobody else (the helper got it)" \
    test "$(plog 'dns AAAA ipv4only.arpa answered')" = 1
check "R76a: the query left on wwan0 and none on br-lan (the plain bench)" count_check
gcheck "R76a: the helper got the operator's own prefix, not the well-known one" \
    "ps w | grep '[4]64xlatcfg' | grep -q '${PFX}' && ! ps w | grep '[4]64xlatcfg' | grep -q '64:ff9b::'"
gcheck "R76d: one 464xlatcfg, one nat46 device, a pid file that names it" \
    '[ "$(ps w | grep -c "[4]64xlatcfg")" = 1 ] && [ -e /sys/class/net/464-wwan_6_4 ] &&
     grep -qa 464xlatcfg "/proc/$(cat /var/run/464-wwan_6_4.pid)/cmdline"'
# the line is written a moment after the interface is up (the check polls netifd every 2 s): wait for it, then
# a few seconds more for any other line, and show what is there
gcheck "R76: one syslog line says the translation is up, with the prefix; no other lw-clat line" \
    "i=0; until logread | grep -q 'lw-clat: translated IPv4 is up'; do i=\$((i + 1)); [ \$i -lt 20 ] || break; sleep 1; done; sleep 4
     logread | grep lw-clat >/tmp/clat-lines; cat /tmp/clat-lines
     [ \"\$(grep -c . /tmp/clat-lines)\" = 1 ] && grep -q 'translated IPv4 is up on 464-wwan_6_4, prefix ${PFX}' /tmp/clat-lines" 60
gcheck "R76: the IPv4 default route is the translation's (metric 2048)" \
    'ip -4 route show default | grep -q "dev 464-wwan_6_4.* metric 2048"'
gcheck "R76: the router reaches 8.8.8.8 by ping" 'ping -c 3 -W 3 8.8.8.8'
check "the NAT64 saw the translated pings of 8.8.8.8" test "$(plog '^echo4 8.8.8.8 ')" -ge 3
gcheck "R76: the router opens a TCP connection to 8.8.8.8 and gets the answer back" \
    'r=$(echo hello | timeout 6 nc 8.8.8.8 80); echo "got: $r"; [ "$r" = "lwvm-nat64 8.8.8.8" ]'
check "the NAT64 saw the connection" test "$(plog '^tcp4 8.8.8.8 80 ')" -ge 1
gcheck "R76/R76a: dnsmasq of the router gives the operator's prefix for an IPv4-only name (rebind protection leaves it)" \
    'nslookup -type=AAAA ipv4-only.example.net 127.0.0.1 | grep -q "3fff:64:6464::"'
gcheck "R76: the router resolves an IPv4-only name and reaches its IPv4 address by ping and by TCP" \
    'ping -4 -c 2 -W 3 ipv4-only.example.net &&
     a=$(nslookup -type=A ipv4-only.example.net 127.0.0.1 | awk "/^Name:/ { n = 1 } n && /^Address/ { print \$NF; exit }") &&
     [ "$a" = 8.8.4.4 ] && r=$(echo hello | timeout 6 nc "$a" 80) && echo "got: $r" && [ "$r" = "lwvm-nat64 8.8.4.4" ]'
gcheck "R77: the family check counts the IPv4 answer through 464-wwan_6_4 (probe.sh)" \
    '. /usr/lib/lw/common.sh; . /usr/lib/lw/probe.sh; rc=0; lw_probe_round recover || rc=$?
     echo "rc=$rc has4=$LW_P_HAS4 has6=$LW_P_HAS6 xlat=$LW_P_XLAT v6only=$LW_P_V6ONLY dev4=$LW_P_DEV4 ok4=$LW_P_OK4 ok6=$LW_P_OK6"
     [ "$rc" = 0 ] && [ "$LW_P_HAS4/$LW_P_HAS6/$LW_P_XLAT/$LW_P_V6ONLY/$LW_P_DEV4/$LW_P_OK4/$LW_P_OK6" = "1/1/1/1/464-wwan_6_4/1/1" ]' 60
# the LAN guest: DHCP from the router, then IPv4 over the translation
must "LAN guest boots" lg_start
lg_check "LAN guest: address from the router and the router as default route" \
    'i=0; until ip addr show eth0 | grep -q "inet "; do i=$((i + 1)); [ $i -lt 40 ] || exit 1; sleep 1; done
     ip route | grep -q "^default via "'
n0=$(plog '^echo4 8.8.8.8 ')
lg_check "R76/R77: the LAN guest reaches 8.8.8.8 through the router by ping" 'ping -c 3 -W 3 8.8.8.8'
check "the NAT64 saw the LAN guest's pings" test "$(($(plog '^echo4 8.8.8.8 ') - n0))" -ge 3
lg_check "R76: the LAN guest opens a TCP connection to 8.8.8.8 through the router" \
    'r=$(echo hello | nc 8.8.8.8 80); echo "got: $r"; [ "$r" = "lwvm-nat64 8.8.8.8" ]'
lg_check "R76: the LAN guest resolves an IPv4-only name through the router's dnsmasq and reaches it (ping, TCP)" \
    'ping -4 -c 2 -W 3 ipv4-only.example.net &&
     a=$(nslookup -type=A ipv4-only.example.net | awk "/^Name:/ { n = 1 } n && /^Address/ { print \$NF; exit }") &&
     [ "$a" = 8.8.4.4 ] && r=$(echo hello | nc "$a" 80) && echo "got: $r" && [ "$r" = "lwvm-nat64 8.8.4.4" ]'
lg_check "R76/R76a: the LAN guest gets the operator's prefix in an AAAA answer of the router's dnsmasq" \
    'nslookup -type=AAAA ipv4-only.example.net | grep -q "3fff:64:6464::"'
gcheck "R75: the translation device is in the wan zone and its IPv4 leaves as 192.0.0.1 (fw4), wwan0 has no IPv4" \
    '! ip -4 addr show wwan0 | grep -q "inet " &&
     nft list ruleset | grep -q "iifname { .*464-wwan_6_4.* } jump forward_wan" &&
     nft list ruleset | grep -q "oifname \"464-wwan_6_4\" .*snat ip to 192.0.0.1"'

if [ "${LWVM_CLAT_HOLD:-0}" = 1 ]; then
    echo "LWVM-CLAT-HOLD guest in $RUN, create $RUN/done to go on"
    until [ -e "$RUN/done" ]; do sleep 2; done
fi

# ---- the helper dies, the ladder's run sets the translation up again (R76c) ---------------------------
echo "# the helper dies"
UP0=$(vm_sh 'ubus call network.interface.wwan status | jsonfilter -e "@.uptime"' | tr -d '\r')
gcheck "kill the helper: netifd does not know, the interface still says up" \
    'kill "$(cat /var/run/464-wwan_6_4.pid)"; sleep 1; [ "$(ps w | grep -c "[4]64xlatcfg")" = 0 ] &&
     [ "$(ubus call network.interface.wwan_6_4 status | jsonfilter -e "@.up")" = true ]'
# no event of the interface fires: only the run of wwan-recover, which the cron makes every 5 min
gcheck "R76c: one run of wwan-recover (the ladder's period) sets the translation up again" \
    '/usr/sbin/wwan-recover; i=0; until [ "$(ps w | grep -c "[4]64xlatcfg")" = 1 ] && ping -c 1 -W 3 8.8.8.8 >/dev/null; do
        i=$((i + 1)); [ $i -lt 20 ] || exit 1; sleep 2; done' 180
check "R76c: a line says it stopped, a line says it is up again; no leftovers of the first helper" \
    vm_wait_for 'logread | grep lw-clat | grep -q "translated IPv4 stopped on 464-wwan_6_4, setting it up again" &&
     [ "$(logread | grep lw-clat | grep -c "translated IPv4 is up")" = 2 ]' 30
check "R76c: one helper, one device, one set of rules after the second setup" one_translation
gcheck "R12c, R76c: wwan was not restarted by it (its uptime kept counting from $UP0), no failure counted" \
    "[ \"\$(ubus call network.interface.wwan status | jsonfilter -e '@.uptime')\" -gt $UP0 ] && [ ! -e /etc/wwan-recover.state ]"
gcheck "R76: TCP to 8.8.8.8 works again" 'r=$(echo hello | timeout 6 nc 8.8.8.8 80); [ "$r" = "lwvm-nat64 8.8.8.8" ]'
gcheck "the helper dies twice more: three setups leave one helper, one device, one set of rules" \
    'for _ in 1 2; do kill "$(cat /var/run/464-wwan_6_4.pid)"; sleep 1; /usr/sbin/wwan-recover; sleep 3; done
     [ "$(ps w | grep -c "[4]64xlatcfg")" = 1 ] && [ "$(ip -o link show | grep -c " 464-wwan_6_4")" = 1 ] &&
     [ "$(ip -6 rule | grep -c "lookup prelocal")" = 1 ]' 240

# ---- the end of a session (R76b, R76c) -----------------------------------------------------------------------
echo "# the session ends: ifdown of wwan, no ifup after it"
NOTRANS='! ubus call network.interface.wwan_6_4 status >/dev/null 2>&1 && [ "$(ps w | grep -c "[4]64xlatcfg")" = 0 ] &&
    [ ! -e /sys/class/net/464-wwan_6_4 ] && ! ls /tmp/464-*-anycast >/dev/null 2>&1 && [ ! -e /var/run/lw-clat/active ] &&
    [ "$(ip -6 rule | grep -c "from all lookup local")" = 1 ] && [ "$(ip -6 rule | grep -c prelocal)" = 0 ]'
must "ifdown of wwan" vm_sh 'ifdown wwan'
check "R76b: the end of the session took the translation away: no interface, helper, device, marker or rule" \
    vm_wait_for "$NOTRANS" 60
gcheck "R76b: the pid file and the nat46 device are gone too" '[ ! -e /var/run/464-wwan_6_4.pid ] && ! grep -q "^add 464-wwan_6_4" /proc/net/nat46/control'
note "the next session: ifup wwan"
must "ifup of wwan" vm_sh 'ifup wwan'
must "wwan_6 is up again" child_up
check "the next session gets its translation" translated 90
gcheck "R76: it works (the first packets may be lost, see PING_OK)" "$PING_OK; ping -c 2 -W 3 8.8.8.8"

echo "# a new session with the same handles and another operator prefix"
PFX2=3fff:64:7777::/96
pset prefix "$PFX2"
must "the session starts again" new_session
must "wwan_6 is up again" child_up
check "the translation of the new session is up" translated 90
gcheck "R76a, R76c: the helper of the new session has the new prefix, not the old one (an old interface that netifd kept was not taken over)" \
    "ps w | grep '[4]64xlatcfg' | grep -q '$PFX2' && ! ps w | grep '[4]64xlatcfg' | grep -q '3fff:64:6464'"
gcheck "R76: the first packets of the new session go through (see PING_OK)" "$PING_OK"
gcheck "R76: TCP to 8.8.8.8 goes over the new prefix" 'r=$(echo hello | timeout 6 nc 8.8.8.8 80); [ "$r" = "lwvm-nat64 8.8.8.8" ]'
check "R76c: one helper, one device, one set of rules after the new session" one_translation

# ---- DNS64 answers late (R76a) -------------------------------------------------------------------------------
echo "# the operator's DNS64 does not answer at the start"
pset dns64 off
must "the session starts again without the DNS64" new_session
must "wwan is up again" wwan_up
must "wwan_6 is up again" child_up
sleep 30
check "R76a: no translation without a DNS64 answer" no_translation
check "R76a: the DNS64 was asked and gave nothing" test "$(plog 'dns AAAA ipv4only.arpa off')" -ge 1
gcheck "R76a: IPv6 works, IPv4 does not, one line says so, wwan not restarted" \
    'ping -6 -c 1 -W 3 2001:4860:4860::8888 >/dev/null && ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 &&
     [ "$(logread | grep -c "no IPv4 for the router and the LAN yet")" = 1 ] &&
     logread | grep "no IPv4 for the router and the LAN yet" | grep -q "IPv6 works"'
gnote 'logread | grep -E "lw-clat|odhcp6c|464xlat" | tail -n 30; ls -la /var/run/lw-clat; for f in /var/run/lw-clat/*; do echo "$f: $(cat $f)"; done; ps w | grep -E "lw-clat|464" | grep -v grep; ubus list | grep wwan; ip -6 rule'
echo "# the DNS64 answers again, a ladder period later"
pset dns64 on
gcheck "R76c: the run of wwan-recover finds the DNS64 and sets the translation up, with no restart of wwan" \
    'u=$(ubus call network.interface.wwan status | jsonfilter -e "@.uptime"); /usr/sbin/wwan-recover
     i=0; until ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; do i=$((i + 1)); [ $i -lt 20 ] || exit 1; sleep 2; done
     [ "$(ubus call network.interface.wwan status | jsonfilter -e "@.uptime")" -gt "$u" ]' 180
gnote 'logread | grep -E "lw-clat" | tail -n 20; ls -la /var/run/lw-clat; ubus call network.interface.wwan_6_4 status | head -n 8'
check "the translation is up, one helper, one device" one_translation

echo "# the DNS64 answers late, within the check of the new session"
# `drop`: no answer at all, so every question of the check waits out its 4 s
pset dns64 drop
must "the session starts again" new_session
must "wwan_6 is up again" child_up
sleep 3
pset dns64 on
check "R76a: the check of the new session finds the DNS64 that came back (hotplug of wwan_6, no ladder run)" translated 40 ||
    gnote 'date; logread | grep -E "lw-clat" | tail -n 8; for f in /var/run/lw-clat/*; do echo "$f: $(cat $f)"; done; ps w | grep -E "[l]w-clat|[n]slookup"; ip -6 route | grep 53; ubus call network.interface.wwan_6_4 status | head -n 4'
gcheck "R76a: the translation works (the first packets may be lost, see PING_OK)" "$PING_OK; ping -c 2 -W 3 8.8.8.8"

# ---- a more specific route to the DNS64 server (R76a) ----------------------------------------------------------
echo "# a route to the DNS64 server that does not leave on the session's device"
must "a more specific route to the server over br-lan" vm_sh 'ip -6 route add 2001:db8:64::53/128 dev br-lan metric 1'
must "the session starts again" new_session
must "wwan_6 is up again" child_up
sleep 25
check "R76a: no translation: the server is not asked" no_translation
gnote 'logread | grep -E "lw-clat" | tail -n 20; ip -6 route; ip -6 route get 2001:db8:64::53 from 2001:db8:64:100:5054:ff:fe52:4802'
gcheck "R76a: one line says the route does not leave on wwan0" \
    '[ "$(logread | grep -c "does not leave on wwan0")" = 1 ]'
must "the route is removed" vm_sh 'ip -6 route del 2001:db8:64::53/128 dev br-lan'
gcheck "R76c: the run of wwan-recover finds the server on the right path and sets the translation up" \
    '/usr/sbin/wwan-recover; i=0; until ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; do i=$((i + 1)); [ $i -lt 20 ] || exit 1; sleep 2; done' 180
check "the translation is up, one helper, one device" one_translation

# ---- an unscoped default route of another uplink (the review's setup, R76a, R18c) -----------------------------------
# busybox nslookup takes the route the kernel finds for a query with no source; a default over br-lan
# with a lower metric than the session's bound default answers that lookup, so a check of the route
# `from` the child's address says wwan0 while the query goes out on br-lan (measured here: 0 packets
# on wwan0, 2 on br-lan). The check makes a host route for the query: the packets are counted
echo "# an unscoped default route over br-lan (the DNS query has to leave on wwan0 all the same)"
must "counters for the DNS queries, per device" count_on
must "an unscoped default via br-lan, preferred to the session's bound one" vm_sh 'ip -6 route add default dev br-lan metric 256'
gcheck "the lookup with no source says br-lan (the case the check must not fall for)" \
    'ip -6 route get 2001:db8:64::53 | grep -q " dev br-lan "'
must "the session starts again" new_session
must "wwan_6 is up again" child_up
check "R76a: the translation comes up" translated 90
check "R76a: the query left on wwan0 and none on br-lan" count_check
gcheck "R76a: no host route to the server is left" '[ -z "$(ip -6 route show 2001:db8:64::53/128)" ]'
must "the counters and the extra default are removed" vm_sh 'nft delete table inet c1count; ip -6 route del default dev br-lan metric 256'
check "the translation is up, one helper, one device" one_translation

# ---- the next session is a session of its own -------------------------------------------------------------------
echo "# the IPv4 call comes back"
must "dual-stack session again" wwan_mode dual
must "wwan is up with both calls" wwan_up
check "R76b: a session with native IPv4 takes the translation down" \
    vm_wait_for '! ubus call network.interface.wwan_6_4 status >/dev/null 2>&1 && [ "$(ps w | grep -c "[4]64xlatcfg")" = 0 ] &&
        [ ! -e /sys/class/net/464-wwan_6_4 ] && ! ls /tmp/464-*-anycast >/dev/null 2>&1 &&
        [ "$(ip -6 rule | grep -c "lookup")" = 2 ] && [ ! -e /var/run/lw-clat/active ]' 90
gnote 'ip -6 rule; ip -4 route; logread | grep lw-clat'
echo "# and the IPv4-only session of the owner again"
must "IPv4-only session" wwan_mode v4
must "wwan is up with an IPv4 call" wwan_up
check "R76b: nothing of a translation is left in the IPv4-only session" no_translation
gnote 'echo "packets lost before the first reply after a setup (one line per probe):"; cat /tmp/clat-first-lost'
echo "# the record of the IPv6-only session is still there; a dual-stack session with a child must not start the check"
gcheck "the record of the earlier IPv6-only session is left (an IPv4-only session runs no command about it)" '[ -e /var/run/lw-clat/v6only ]'
must "the check is replaced by a recorder again" rec_on
must "dual-stack session, IPv6 through the child" wwan_mode dualchild
must "wwan is up with both calls" wwan_up
must "wwan_6 runs odhcp6c" child_up
sleep 10
gcheck "R76b: a stale record is emptied and the child's ifup starts nothing" \
    '[ -f /var/run/lw-clat/v6only ] && [ ! -s /var/run/lw-clat/v6only ] && [ ! -s /tmp/clat-calls ] && [ ! -e /var/run/lw-clat/active ]'

finish
