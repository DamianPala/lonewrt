#!/bin/sh
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh

PATH=/fw/tests/lan6/stubs:$PATH
mkdir -p "$T" /var/run
cp /fw/src/files/usr/lib/lw/lan6.sh /tmp/lan6.sh
# shellcheck source=src/files/usr/lib/lw/lan6.sh
. /tmp/lan6.sh

cat >/etc/config/network <<'UCI'
config interface 'lan'
    option proto 'static'
    list ipaddr '192.0.2.1/24'
    option ip6assign '64'
    option lw_ipv6 '1'
UCI
cat >/etc/config/dhcp <<'UCI'
config dhcp 'lan'
    option interface 'lan'
    option ra 'disabled'
    option dhcpv6 'disabled'
    option dhcpv4 'server'
    list ra_flags 'managed-config'
config dhcp 'guest'
    option interface 'guest'
    option ra 'server'
    option dhcpv6 'server'
UCI
cp /etc/config/network "$T/network"
cp /etc/config/dhcp "$T/dhcp"

parent() {
    printf '{"up":true,"l3_device":"wwan0","data":{%s}}\n' "$1" >"$T/wwan.json"
}

prefix() {
    cat >"$T/lan.json" <<JSON
{"up":true,"l3_device":"br-lan","ipv6-prefix-assignment":[
  {"address":"$1::","mask":64,"local-address":{"address":"$1::1","mask":64}}
]}
JSON
    printf '2001:db8:ffff::1 from %s::1 via fe80::1 dev wwan0\n' "$1" >"$T/route"
}

child() {
    cat >"$T/wwan_6.json" <<JSON
{"up":true,"l3_device":"wwan0","ipv6-prefix":[
  {"address":"$1::","mask":$2,"assigned":{"lan":{"address":"$3::","mask":64}}}
]}
JSON
}

# lan6_event: one event as the init script does it when the signal succeeded
lan6_event() {
    lan6_configure event
    lan6_applied
}

ram() { uci -q get "$LW_LAN6_CONFIG/dhcp.$1"; }

# lan6_withdraw: what the init script does at a loss, in two reloads: the withdrawal advertisement,
# then the one that switches the server off (R74c)
lan6_withdraw() {
    lw_expect_eq "$(lan6_event)" withdraw "$1: the first reload is the withdrawal"
    lw_expect_eq "$(ram lan.ra)/$(ram lan.ra_default)/$(ram lan.max_preferred_lifetime)" server/0/60 \
        "$1: withdrawal advertisement: server still on, route check on, prefix preferred at most 60 s"
    lw_expect_eq "$(lan6_event)" reload "$1: the second reload switches the server off"
    lw_expect_eq "$(ram lan.ra)/$(ram lan.ra_default)" disabled/0 "$1: final advertisement, then none"
    lw_expect_eq "$(ram lan.ra_flags)" none "$1: no DHCPv6 indication on the final advertisement"
    lw_expect_eq "$(lan6_event)" "" "$1: no repeated withdrawal"
}

parent '"cid_4":4,"pdh_4":40'
uci set dhcp.guest.dhcpv6=disabled
lan6_configure boot
lw_expect_eq "$(uci get dhcp.guest.dhcpv6)" disabled "the staged edit is still present"
uci revert dhcp
lw_expect_eq "$(ram guest.dhcpv6)" server "R74e staged guest edit is excluded from live odhcpd"
lw_expect_eq "$(ram lan.ra)" disabled "R74b IPv4-only RA"
lw_expect_eq "$(ram lan.dhcpv6)" disabled "R74b IPv4-only DHCPv6"
[ ! -s "$T/syslog" ] || lw_fail "R74b IPv4-only warning"
lw_expect_eq "$(lan6_event)" "" "R74e no IPv4-only reload"

parent '"cid_4":4,"pdh_4":40,"cid_6":6,"pdh_6":60'
child 2001:db8:1 64 2001:db8:1
echo '{"up":true,"l3_device":"br-lan"}' >"$T/lan.json"
lw_expect_eq "$(lan6_event)" "" "R74a waits for LAN assignment"
prefix 2001:db8:1
lw_expect_eq "$(lan6_event)" reload "R74a /64 published"
lw_expect_eq "$(ram lan.ra)" server "R74a SLAAC server"
lw_expect_eq "$(ram lan.max_preferred_lifetime)" 1800 "R74c cap on preferred lifetime"
lw_expect_eq "$(ram lan.ra_flags)" none "R74a no DHCPv6 indication"
lw_expect_eq "$(ram lan.dns)" 2001:db8:1::1 "R74a RDNSS"
lw_expect_eq "$(lan6_event)" "" "R74e stable events do not reload"

child 2001:db8:2 56 2001:db8:2:1
prefix 2001:db8:2:1
lw_expect_eq "$(lan6_event)" reload "R74c renumber on delegated prefix"
lw_expect_eq "$(ram lan.dns)" 2001:db8:2:1::1 "R74 PD /64"

parent '"cid_6":6,"pdh_6":60'
lan6_configure boot
lw_expect_eq "$(ram lan.ra)" server "R74d/R74f boot on IPv6, without CLAT"
echo 'not json' >"$T/wwan_6.json"
lw_expect_eq "$(lan6_configure event)" unknown "R74c unreadable delegated prefix does not withdraw the LAN"
child 2001:db8:2 56 2001:db8:2:1
: >"$T/child-unreadable"
lw_expect_eq "$(lan6_configure event)" unknown "R74c a failed child status does not withdraw the LAN"
rm -f "$T/child-unreadable"
: >"$T/route-timeout"
lw_expect_eq "$(lan6_configure event)" unknown "R74c a route lookup timeout does not withdraw the LAN"
rm -f "$T/route-timeout"
lw_expect_eq "$(ram lan.ra)/$(ram lan.ra_default)" server/2 "R74c unknown status preserves the active RAM config"
uci set dhcp.guest.dhcpv6=disabled
uci set dhcp.lan.ra=relay
staged_dhcp=$(uci changes dhcp)
: >"$T/route"
lan6_withdraw "R74c route loss"
lw_expect_eq "$(uci changes dhcp)" "$staged_dhcp" "R74e both reloads preserve the pending DHCP edit"
lw_expect_eq "$(ram guest.dhcpv6)" server "R74e neither reload installs the pending DHCP edit"
cmp /etc/config/dhcp "$T/dhcp"
uci revert dhcp

prefix 2001:db8:2:1
lan6_event >/dev/null
parent '"cid_4":4,"pdh_4":40'
lan6_withdraw "R74c confirmed call loss"

# R74f: the watcher confirmed that the IPv6 call of this session is gone in the modem; netifd still
# shows the prefix and the route, so only the flag of the watcher switches the LAN off. The flag
# holds the call (client/handle) and the birth of the session on the clock of the uptime file.
LW_LAN6_LOST=$T/v6lost
export LW_LAN6_LOST
echo 1000.00 1000.00 >"$T/uptime"
cat >"$T/wwan.json" <<'JSON'
{"up":true,"uptime":100,"l3_device":"wwan0","data":{"cid_4":4,"pdh_4":40,"cid_6":6,"pdh_6":60}}
JSON
child 2001:db8:2 64 2001:db8:2
prefix 2001:db8:2
lw_expect_eq "$(lan6_event)" reload "R74f the session is up again"
lw_expect_eq "$(ram lan.ra)" server "R74f server on"
echo "6/60 900" >"$LW_LAN6_LOST"
lan6_withdraw "R74f call lost in the modem"
echo "6/61 900" >"$LW_LAN6_LOST"
lw_expect_eq "$(lan6_event)" reload "R74f a flag of another call does not count"
lw_expect_eq "$(ram lan.ra)" server "R74f flag of another handle: server on"
echo "6/60 700" >"$LW_LAN6_LOST"
lw_expect_eq "$(lan6_event)" "" "R74f a flag of an earlier start of the interface does not count"
echo "6/60 -" >"$LW_LAN6_LOST"
lan6_withdraw "R74f flag without a birth"
rm -f "$LW_LAN6_LOST"
lw_expect_eq "$(lan6_event)" reload "R74f the flag is gone: the LAN follows the session again"
lw_expect_eq "$(ram lan.ra)" server "R74f server back on"
echo "6/60 -" >"$LW_LAN6_LOST"
lan6_event >/dev/null
lan6_configure boot
lw_expect_eq "$(ram lan.ra)/$(ram lan.ra_default)" disabled/0 "R74f boot with the flag set: server off, no withdrawal"
rm -f "$LW_LAN6_LOST"
# Direct QMI publication has the same allocation shape on the parent, with no wwan_6.
cat >"$T/wwan.json" <<'JSON'
{"up":true,"l3_device":"wwan0","data":{"cid_6":6,"pdh_6":-61},"ipv6-prefix":[
  {"address":"2001:db8:2:1::","mask":64,"assigned":{"lan":{"address":"2001:db8:2:1::","mask":64}}}
]}
JSON
rm -f "$T/wwan_6.json"
printf '2001:db8:ffff::1 dev wg0\n' >"$T/route"
lw_expect_eq "$(lan6_event)" "" "R74a rejects a route through another interface"
prefix 2001:db8:2:1
lw_expect_eq "$(lan6_event)" reload "R74f accepts QMI parent publication"
lw_expect_eq "$(ram lan.ra)" server "R74a server on parent prefix"
lw_expect_eq "$(ram lan.dhcpv4)" server "R74d DHCPv4"
lw_expect_eq "$(ram guest.ra)/$(ram guest.dhcpv6)" server/server "R74e other LAN"
lw_expect_eq "$(uci changes)" "" "R74e no staged changes"
cmp /etc/config/network "$T/network"
cmp /etc/config/dhcp "$T/dhcp"
echo ok
