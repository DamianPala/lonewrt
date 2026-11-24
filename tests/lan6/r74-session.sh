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

ram() { uci -q -c "$LW_LAN6_CONFIG" get "dhcp.$1"; }

parent '"cid_4":4,"pdh_4":40'
uci set dhcp.guest.dhcpv6=disabled
lan6_configure boot
lw_expect_eq "$(uci get dhcp.guest.dhcpv6)" disabled "the staged edit is still present"
uci revert dhcp
lw_expect_eq "$(ram guest.dhcpv6)" server "R74e staged guest edit is excluded from live odhcpd"
lw_expect_eq "$(ram lan.ra)" disabled "R74b IPv4-only RA"
lw_expect_eq "$(ram lan.dhcpv6)" disabled "R74b IPv4-only DHCPv6"
[ ! -s "$T/syslog" ] || lw_fail "R74b IPv4-only warning"
lw_expect_eq "$(lan6_configure event)" "" "R74e no IPv4-only reload"

parent '"cid_4":4,"pdh_4":40,"cid_6":6,"pdh_6":60'
child 2001:db8:1 64 2001:db8:1
lw_expect_eq "$(lan6_configure event)" "" "R74a waits for LAN assignment"
prefix 2001:db8:1
lw_expect_eq "$(lan6_configure event)" reload "R74a /64 published"
lw_expect_eq "$(ram lan.ra)" server "R74a SLAAC server"
lw_expect_eq "$(ram lan.max_preferred_lifetime)" 1800 "R74c cap on preferred lifetime"
lw_expect_eq "$(ram lan.ra_flags)" none "R74a no DHCPv6 indication"
lw_expect_eq "$(ram lan.dns)" 2001:db8:1::1 "R74a RDNSS"
lw_expect_eq "$(lan6_configure event)" "" "R74e stable events do not reload"

child 2001:db8:2 56 2001:db8:2:1
prefix 2001:db8:2:1
lw_expect_eq "$(lan6_configure event)" reload "R74c renumber on delegated prefix"
lw_expect_eq "$(ram lan.dns)" 2001:db8:2:1::1 "R74 PD /64"

parent '"cid_6":6,"pdh_6":60'
lan6_configure boot
lw_expect_eq "$(ram lan.ra)" server "R74d/R74f boot on IPv6, without CLAT"
: >"$T/route"
lw_expect_eq "$(lan6_configure event)" reload "R74c route loss"
lw_expect_eq "$(ram lan.ra_default)" 0 "R74c restore default-route check for final RA"
lw_expect_eq "$(ram lan.ra)" disabled "R74c stop after withdrawal"
lw_expect_eq "$(ram lan.ra_flags)" none "R74c no DHCPv6 indication on final RA"
lw_expect_eq "$(lan6_configure event)" "" "R74c no repeated withdrawal"

prefix 2001:db8:2:1
lan6_configure event
parent '"cid_4":4,"pdh_4":40'
lw_expect_eq "$(lan6_configure event)" reload "R74c confirmed call loss"
lw_expect_eq "$(ram lan.ra)" disabled "R74c call gone"
# Direct QMI publication has the same allocation shape on the parent, with no wwan_6.
cat >"$T/wwan.json" <<'JSON'
{"up":true,"l3_device":"wwan0","data":{"cid_6":6,"pdh_6":-61},"ipv6-prefix":[
  {"address":"2001:db8:2:1::","mask":64,"assigned":{"lan":{"address":"2001:db8:2:1::","mask":64}}}
]}
JSON
: >"$T/wwan_6.json"
printf '2001:db8:ffff::1 dev wg0\n' >"$T/route"
lw_expect_eq "$(lan6_configure event)" "" "R74a rejects a route through another interface"
prefix 2001:db8:2:1
lw_expect_eq "$(lan6_configure event)" reload "R74f accepts QMI parent publication"
lw_expect_eq "$(ram lan.ra)" server "R74a server on parent prefix"
lw_expect_eq "$(ram lan.dhcpv4)" server "R74d DHCPv4"
lw_expect_eq "$(ram guest.ra)/$(ram guest.dhcpv6)" server/server "R74e other LAN"
lw_expect_eq "$(uci changes)" "" "R74e no staged changes"
cmp /etc/config/network "$T/network"
cmp /etc/config/dhcp "$T/dhcp"
echo ok
