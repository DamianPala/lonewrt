# R73a step 1, R73e, R73g, R73j, R76b: both families granted. With the options of the image (dhcp
# and dhcpv6 omitted) the IPv4 call gets the DHCP child and the IPv6 call its settings on the parent;
# with dhcpv6 set the IPv6 child takes them from the link and leaves out the 464XLAT because a native
# IPv4 call exists. One profile write, the IPv4 call with autoconnect and the IPv6 call without,
# every call stopped by its published handle at the teardown.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

qmi_fixture both-accepted
qmi_run setup ipv4v6 || lw_fail 'dual-stack setup failed'
lw_expect_eq "$(qmi_notify 0 '["link-up"]' | head -n 1)" true 'parent link'
lw_expect_eq "$(qmi_notify 3 '.error[*]')" '' 'setup errors'
lw_expect_eq "$(qmi_notify 0 .data.cid_4)" 17 'IPv4 CID'
lw_expect_eq "$(qmi_notify 0 .data.pdh_4)" -12345678 'signed IPv4 PDH'
lw_expect_eq "$(qmi_notify 0 .data.cid_6)" 18 'IPv6 CID'
lw_expect_eq "$(qmi_notify 0 .data.pdh_6)" 12345679 'IPv6 PDH'
lw_expect_eq "$(cat "$QMI_STATE/calls/ipv4")" '17 -12345678 1' 'active IPv4 call'
lw_expect_eq "$(cat "$QMI_STATE/calls/ipv6")" '18 12345679 0' 'active IPv6 call'
lw_expect_eq "$(qmi_json_lines "$DYNAMIC" '@[*].name')" wwan_4 'children with the image defaults'
lw_expect_eq "$(qmi_child wwan_4 proto)" dhcp 'IPv4 child protocol'
lw_expect_eq "$(qmi_notify 0 '.ip6addr[*].ipaddr')" 2001:db8::2 'IPv6 address from the modem on the parent'
lw_expect_eq "$(qmi_notify 0 '.ip6prefix[*]')" 2001:db8::2/64 'IPv6 prefix from the modem'
lw_expect_eq "$(qmi_count '--modify-profile')" 1 'profile writes (one for the step)'
lw_expect_eq "$(qmi_count 'wds,17 --start-network.*--autoconnect')" 1 'R73g: IPv4 call with autoconnect'
lw_expect_eq "$(qmi_count 'wds,18 --start-network.*--autoconnect')" 0 'R73g: IPv6 call without autoconnect'
lw_expect_eq "$(cat "$QMI_STATE/profile.pdp")" ipv4v6 'profile type'
# R73e: only the sweep before the first call is global
lw_expect_eq "$(qmi_calls_from 'wds,17 --start-network' | grep -c -e 0xffffffff -e --sync || :)" 0 'global operations after a call is up'

qmi_ifdown ipv4v6
lw_expect_eq "$(qmi_arg_count --release-client-id)" 2 'client releases'
qmi_modem_clean 'after teardown'

# dhcpv6: the IPv6 child takes the settings from the link, without the 464XLAT (R76b)
qmi_fixture both-accepted
qmi_run setup ipv4v6 '"dhcpv6":true' || lw_fail 'dual-stack setup with dhcpv6 failed'
lw_expect_eq "$(qmi_json_lines "$DYNAMIC" '@[*].name' | tr '\n' ' ')" 'wwan_6 wwan_4 ' 'children'
lw_expect_eq "$(qmi_child wwan_6 proto)" dhcpv6 'IPv6 child protocol'
lw_expect_eq "$(qmi_child wwan_6 iface_464xlat)" 0 'no 464XLAT beside a native IPv4 call'
lw_expect_eq "$(qmi_child wwan_6 extendprefix)" 1 'extend IPv6 prefix to LAN'
lw_expect_eq "$(qmi_count 'wds,18 --get-current-settings')" 0 'R73j: no settings read when the link gives them'
echo ok
