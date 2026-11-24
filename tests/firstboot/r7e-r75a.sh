#!/bin/sh
. /fw/tests/firstboot/fb-lib

fb_prepare generic
cp /etc/config/firewall "$T/firewall.stock"
has_rules() {
    cp "$T/firewall.stock" /etc/config/firewall
}
rule() {
    uci show firewall | sed -n "s/^\(firewall\.[^.]*\)\.name='$1'$/\1/p"
}
has_rules
esp=$(rule Allow-IPSec-ESP)
ike=$(rule Allow-ISAKMP)
fb_uci_defaults
fb_expect network.lan.ip6assign 64
fb_expect network.lan.lw_ipv6 1
fb_expect "$esp.family" ipv4
fb_expect "$ike.family" ipv4
fb_expect "$(rule Allow-ICMPv6-Forward).family" ipv6
wan=$(rule wan)
fb_expect "$wan.input" REJECT
fb_expect "$wan.forward" DROP
fb_expect "$wan.network" 'wan wan6 wwan wwan_4 wwan_6 wwan_6_4'
fb_expect network.wwan.pdptype ipv4

old_lan() {
    uci -q delete network.lan.lw_ipv6 || :
    uci -q delete network.lan.ip6class || :
    uci set network.lan.ip6assign="$1"
    uci set dhcp.lan.ra="$2"
    uci set dhcp.lan.dhcpv6="$2"
    uci commit
}

lan_ip=$(fb_get network.lan.ipaddr)
uci set network.wwan.pdptype=ipv4v6
uci add_list network.lan.ipaddr=192.0.2.1/24
uci set network.guest=interface
uci set network.guest.ip6assign=60
uci set dhcp.guest=dhcp
uci set dhcp.guest.ra=server
has_rules
uci set "$esp.src_ip=192.0.2.4"
uci delete "$ike"
old_lan 60 disabled
fb_uci_defaults
fb_expect network.lan.ip6assign 64
fb_expect network.lan.lw_ipv6 1
fb_expect network.wwan.pdptype ipv4v6
fb_expect "$esp.family" '<unset>'
fb_expect "$ike" '<unset>'
fb_expect network.guest.ip6assign 60
fb_expect dhcp.guest.ra server
fb_expect network.lan.ipaddr "$lan_ip"

old_lan 56 server
fb_uci_defaults
fb_expect network.lan.ip6assign 56
fb_expect dhcp.lan.ra server
fb_expect network.lan.lw_ipv6 '<unset>'

# A kept 0.6.0 LAN gets the original odhcpd defaults from 15_odhcpd.
old_lan 60 server
uci set dhcp.lan.ra_slaac=1
uci -q delete dhcp.lan.ra_flags || :
uci add_list dhcp.lan.ra_flags=managed-config
uci add_list dhcp.lan.ra_flags=other-config
uci set network.globals.ula_prefix='fd00:1234:5678::/48'
uci set network.wwan.pdptype=ipv4
uci commit
fb_uci_defaults
fb_expect network.lan.ip6assign 64
fb_expect network.lan.ip6class 'wwan wwan_6'
fb_expect dhcp.lan.ra disabled
fb_expect dhcp.lan.dhcpv6 disabled
fb_expect network.wwan.pdptype ipv4
fb_expect dhcp.lan.dhcpv4 server
fb_expect dhcp.odhcpd.leasetrigger /usr/sbin/odhcpd-update
echo ok
