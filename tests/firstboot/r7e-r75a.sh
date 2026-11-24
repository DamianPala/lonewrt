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

# R7e, D201: the owner's measured 0.6.0 LAN (dhcp.lan of the router, 2026-11-24: interface, start,
# limit, leasetime, dhcpv4, dhcpv6, ra, ra_slaac, ra_flags and nothing else; network.lan.ip6assign
# 60) is moved, with its IPv4 options kept; the same LAN with one more IPv6 option of its own is not
# touched, whichever option it is, and neither is a 0.6.1 LAN (advertisements off) that has one.
lan_060() {
    uci -q delete dhcp.lan || :
    uci -q delete network.lan.lw_ipv6 || :
    uci -q delete network.lan.ip6class || :
    for o in ip6hint ip6weight ip6addr ip6prefix ip6ifaceid delegate ip6gw ipv6; do
        uci -q delete "network.lan.$o" || :
    done
    uci set network.lan.ip6assign=60
    uci set dhcp.lan=dhcp
    uci set dhcp.lan.interface=lan
    uci set dhcp.lan.start=100
    uci set dhcp.lan.limit=150
    uci set dhcp.lan.leasetime=12h
    uci set dhcp.lan.dhcpv4=server
    uci set dhcp.lan.dhcpv6=server
    uci set dhcp.lan.ra=server
    uci set dhcp.lan.ra_slaac=1
    uci add_list dhcp.lan.ra_flags=managed-config
    uci add_list dhcp.lan.ra_flags=other-config
    uci set network.wwan.pdptype=ipv4
    uci commit
}
# 0.6.1 switched the two off and left the stock SLAAC option and flags in the section
lan_061() {
    lan_060
    uci set dhcp.lan.ra=disabled
    uci set dhcp.lan.dhcpv6=disabled
    uci commit
}
lan_061_bare() {
    lan_061
    uci -q delete dhcp.lan.ra_slaac || :
    uci -q delete dhcp.lan.ra_flags || :
    uci commit
}
fb_expect_moved() {
    fb_expect network.lan.ip6assign 64
    fb_expect network.lan.ip6class 'wwan wwan_6'
    fb_expect network.lan.lw_ipv6 1
    fb_expect dhcp.lan.ra disabled
    fb_expect dhcp.lan.dhcpv6 disabled
}

lan_060
fb_uci_defaults
fb_expect_moved
fb_expect dhcp.lan.start 100
fb_expect dhcp.lan.limit 150
fb_expect dhcp.lan.leasetime 12h
fb_expect dhcp.lan.dhcpv4 server

for base in lan_061 lan_061_bare; do
    "$base"
    fb_uci_defaults
    fb_expect_moved
done

# The flags are a set, so reversing the order keeps the stock policy.
lan_060
uci delete dhcp.lan.ra_flags
uci add_list dhcp.lan.ra_flags=other-config
uci add_list dhcp.lan.ra_flags=managed-config
uci commit
fb_uci_defaults
fb_expect_moved

# a customised LAN stays as it was, with its extra option
for base in lan_060 lan_061 lan_061_bare; do
    for extra in ra_maxinterval=600 ra_mininterval=200 ra_lifetime=1800 ra_mtu=1400 ra_preference=high \
        ra_default=1 ra_hoplimit=64 ra_reachabletime=30000 ra_retranstime=1000 ndp=relay master=1 \
        dns_service=1 preferred_lifetime=1h ra_dns=1 ra_useleasetime=1 domain=example.test \
        max_preferred_lifetime=300 max_valid_lifetime=600 prefix_filter=2001:db8::/32 \
        ndp_from_link_local=1 upstream=guest ignore=1; do
        "$base"
        uci set "dhcp.lan.$extra"
        uci commit
        want_ra=$(fb_get dhcp.lan.ra)
        want_v6=$(fb_get dhcp.lan.dhcpv6)
        fb_uci_defaults
        fb_expect network.lan.ip6assign 60
        fb_expect network.lan.lw_ipv6 '<unset>'
        fb_expect network.lan.ip6class '<unset>'
        fb_expect dhcp.lan.ra "$want_ra"
        fb_expect dhcp.lan.dhcpv6 "$want_v6"
        fb_expect "dhcp.lan.${extra%%=*}" "${extra#*=}"
    done
    # a list option: the DNS server announced in the advertisements
    "$base"
    uci add_list dhcp.lan.dns=2001:db8:53::1
    uci commit
    fb_uci_defaults
    fb_expect network.lan.ip6assign 60
    fb_expect network.lan.lw_ipv6 '<unset>'
    fb_expect dhcp.lan.dns 2001:db8:53::1
    # an IPv6 option of the network section
    for extra in ip6hint=10 ip6weight=3 delegate=0 ip6gw=2001:db8:1::1 ipv6=0; do
        "$base"
        uci set "network.lan.$extra"
        uci commit
        fb_uci_defaults
        fb_expect network.lan.ip6assign 60
        fb_expect network.lan.lw_ipv6 '<unset>'
        fb_expect "network.lan.${extra%%=*}" "${extra#*=}"
    done
done

lan_060
uci set network.lan.lw_ipv6=0
uci commit
fb_uci_defaults
fb_expect network.lan.ip6assign 60
fb_expect network.lan.lw_ipv6 0

# A section named lan may be assigned to another interface.
lan_060
uci set dhcp.lan.interface=guest
uci commit
fb_uci_defaults
fb_expect network.lan.lw_ipv6 '<unset>'
fb_expect dhcp.lan.interface guest
fb_expect dhcp.lan.ra server

# other values of the SLAAC option and flags, and a 0.6.0 LAN without them, are not a stock set
lan_060
uci set dhcp.lan.ra_flags='managed-config other-config'
uci commit
fb_uci_defaults
fb_expect network.lan.lw_ipv6 '<unset>'
fb_expect dhcp.lan.ra server
lan_061
uci set dhcp.lan.ra_slaac=0
uci commit
fb_uci_defaults
fb_expect network.lan.lw_ipv6 '<unset>'
fb_expect dhcp.lan.ra disabled
fb_expect dhcp.lan.ra_slaac 0
lan_061
uci -q delete dhcp.lan.ra_flags || :
uci add_list dhcp.lan.ra_flags=managed-config
uci commit
fb_uci_defaults
fb_expect network.lan.lw_ipv6 '<unset>'
fb_expect dhcp.lan.ra_flags managed-config
lan_060
uci -q delete dhcp.lan.ra_slaac || :
uci commit
fb_uci_defaults
fb_expect network.lan.lw_ipv6 '<unset>'
fb_expect dhcp.lan.ra server
echo ok
