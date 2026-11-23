# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

qmi_fixture both-accepted
# Stock qmi.sh configures IPv6 on the parent unless dhcpv6 is enabled.
qmi_run setup ipv4v6 '"dhcpv6":true' || lw_fail 'dual-stack setup failed'

lw_expect_eq "$(qmi_notify 0 '["link-up"]')" true 'parent link'
lw_expect_eq "$(qmi_notify 3 '.error[*]')" '' 'setup errors'
lw_expect_eq "$(qmi_notify 0 .data.cid_4)" 17 'IPv4 CID'
lw_expect_eq "$(qmi_notify 0 .data.cid_6)" 18 'IPv6 CID'
lw_expect_eq "$(qmi_notify 0 .data.pdh_6)" 12345679 'IPv6 PDH'
lw_expect_eq "$(cat "$QMI_STATE/calls/ipv4")" '17 -12345678' 'active IPv4 call'
lw_expect_eq "$(cat "$QMI_STATE/calls/ipv6")" '18 12345679' 'active IPv6 call'
lw_expect_eq "$(qmi_child wwan_4 proto)" dhcp 'IPv4 child protocol'
lw_expect_eq "$(qmi_child wwan_6 proto)" dhcpv6 'IPv6 child protocol'
lw_expect_eq "$(qmi_child wwan_6 ifname)" @wwan 'IPv6 child parent'
lw_expect_eq "$(qmi_child wwan_6 iface_464xlat)" 0 '464XLAT for dual stack'
lw_expect_eq "$(qmi_child wwan_6 extendprefix)" 1 'extend IPv6 prefix to LAN'

qmi_run teardown ipv4v6 || lw_fail 'dual-stack teardown failed'
lw_expect_eq "$(qmi_arg_count --release-client-id)" 2 'client releases'
lw_expect_eq "$(ls "$QMI_STATE/clients")" '' 'remaining clients'
lw_expect_eq "$(ls "$QMI_STATE/calls")" '' 'remaining calls'
echo ok
