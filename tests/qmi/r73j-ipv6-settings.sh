# R73j: the session's IPv6 settings come from what the modem reports for the call when that set is
# complete and valid (address, prefix length, gateway, DNS), else from the link (the IPv6 child);
# only one of the two sets them, and an incomplete set publishes nothing. dhcpv6 takes them from
# the link at once. The IPv6 call itself stays published in every case (R73e).
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

# static: the settings of the modem on the parent, no IPv6 child
qmi_fixture ipv6-only
qmi_run setup ipv4v6 || lw_fail 'setup with complete settings failed'
lw_expect_eq "$(qmi_notify 0 '.ip6addr[*].ipaddr')" 2001:db8::2 'address from the modem'
lw_expect_eq "$(qmi_notify 0 '.ip6prefix[*]')" 2001:db8::2/64 'prefix from the modem'
lw_expect_eq "$(qmi_json_lines "$DYNAMIC" '@[*].name')" '' 'no IPv6 child beside the settings'

# invalid reports: no prefix length, no gateway, an address that is not IPv6, no DNS
for row in 'no prefix:"ipv6":{"ip":"2001:db8::2","gateway":"2001:db8::1","dns1":"2001:db8::53"}' \
    'no gateway:"ipv6":{"ip":"2001:db8::2","dns1":"2001:db8::53","ip-prefix-length":64}' \
    'bad address:"ipv6":{"ip":"192.0.2.2","gateway":"2001:db8::1","dns1":"2001:db8::53","ip-prefix-length":64}' \
    'no DNS:"ipv6":{"ip":"2001:db8::2","gateway":"2001:db8::1","ip-prefix-length":64}' \
    'bad prefix length:"ipv6":{"ip":"2001:db8::2","gateway":"2001:db8::1","dns1":"2001:db8::53","ip-prefix-length":200}' \
    'prefix length 0:"ipv6":{"ip":"2001:db8::2","gateway":"2001:db8::1","dns1":"2001:db8::53","ip-prefix-length":0}' \
    'link-local address:"ipv6":{"ip":"fe80::2","gateway":"fe80::1","dns1":"2001:db8::53","ip-prefix-length":64}' \
    'link-local only:"ipv6":{"ip":"fe80::2","gateway":"fe80::1","dns1":"fe80::53","ip-prefix-length":64}' \
    'unique local address:"ipv6":{"ip":"fd00::2","gateway":"fd00::1","dns1":"2001:db8::53","ip-prefix-length":64}' \
    'unspecified address:"ipv6":{"ip":"::","gateway":"2001:db8::1","dns1":"2001:db8::53","ip-prefix-length":64}' \
    'loopback address:"ipv6":{"ip":"::1","gateway":"2001:db8::1","dns1":"2001:db8::53","ip-prefix-length":64}' \
    'address with a zone:"ipv6":{"ip":"2001:db8::2%wwan0","gateway":"2001:db8::1","dns1":"2001:db8::53","ip-prefix-length":64}' \
    'junk gateway:"ipv6":{"ip":"2001:db8::2","gateway":"x:y","dns1":"2001:db8::53","ip-prefix-length":64}' \
    'address with too few groups:"ipv6":{"ip":"2001:db8:2","gateway":"2001:db8::1","dns1":"2001:db8::53","ip-prefix-length":64}' \
    'empty report:"ipv6":{}'; do
    label=${row%%:*}
    qmi_fixture ipv6-only
    printf '{%s}\n' "${row#*:}" >"$QMI_STATE/settings-ipv6.json"
    qmi_run setup ipv4v6 || lw_fail "$label: the start failed"
    lw_expect_eq "$(qmi_notify 3 '.error[*]')" '' "$label: failed starts"
    lw_expect_eq "$(qmi_notify 0 .data.pdh_6)" 12345679 "$label: the IPv6 call is published"
    lw_expect_eq "$(qmi_notify 0 '.ip6addr[*].ipaddr')" '' "$label: no address of the modem set"
    lw_expect_eq "$(qmi_child wwan_6 proto)" dhcpv6 "$label: the link gives the settings"
    lw_expect_eq "$(qmi_child wwan_6 iface_464xlat)" '' "$label: no native IPv4, the translation may run"
done

# a gateway that is link-local is usual on a mobile link and is no reason to refuse the set; a second
# DNS server that is no address is dropped, not published
qmi_fixture ipv6-only
printf '{"ipv6":{"ip":"2001:db8::2","gateway":"fe80::1","dns1":"2001:db8::53","dns2":"junk","ip-prefix-length":64}}\n' \
    >"$QMI_STATE/settings-ipv6.json"
qmi_run setup ipv4v6 || lw_fail 'setup with a link-local gateway failed'
lw_expect_eq "$(qmi_notify 0 '.ip6addr[*].ipaddr')" 2001:db8::2 'address with a link-local gateway'
lw_expect_eq "$(qmi_notify 0 '.dns[*]')" 2001:db8::53 'only the DNS server that is an address'
lw_expect_eq "$(qmi_json_lines "$DYNAMIC" '@[*].name')" '' 'no IPv6 child with a usable set'

# A host-only prefix cannot supply a LAN /64.
qmi_fixture ipv6-only
printf '{"ipv6":{"ip":"2001:db8::2","gateway":"2001:db8::1","dns1":"2001:db8::53","ip-prefix-length":128}}\n' \
    >"$QMI_STATE/settings-ipv6.json"
qmi_run setup ipv4v6 || lw_fail 'setup with a prefix length of 128 failed'
lw_expect_eq "$(qmi_notify 0 '.ip6prefix[*]')" '' 'no static prefix length 128'
lw_expect_eq "$(qmi_child wwan_6 proto)" dhcpv6 'DHCPv6 for prefix length 128'

for gateway in 0:0:0:0:0:0:0:0 0000:0000:0000:0000:0000:0000:0000:0001 0::0 0::01; do
    qmi_fixture ipv6-only
    printf '{"ipv6":{"ip":"2001:db8::2","gateway":"%s","dns1":"2001:db8::53","ip-prefix-length":64}}\n' \
        "$gateway" >"$QMI_STATE/settings-ipv6.json"
    qmi_run setup ipv4v6 || lw_fail "setup with gateway $gateway failed"
    lw_expect_eq "$(qmi_child wwan_6 proto)" dhcpv6 "DHCPv6 for unusable gateway $gateway"
done

# R73j: one verified report. The set that is judged is the set that is published: the modem is read
# once for the IPv6 settings, and what a second read would say (nothing, another address, an
# unusable one) changes nothing
for row in 'empty:{}' \
    'another address:{"ipv6":{"ip":"2001:db8::99","gateway":"2001:db8::1","dns1":"2001:db8::53","ip-prefix-length":64}}' \
    'link-local:{"ipv6":{"ip":"fe80::2","gateway":"fe80::1","dns1":"fe80::53","ip-prefix-length":64}}'; do
    label=${row%%:*}
    qmi_fixture ipv6-only
    printf '%s\n' "${row#*:}" >"$QMI_STATE/settings-ipv6.next.json"
    qmi_run setup ipv4v6 || lw_fail "second read $label: the start failed"
    lw_expect_eq "$(qmi_arg_count --get-current-settings)" 1 "second read $label: reads of the report"
    lw_expect_eq "$(qmi_notify 0 '.ip6addr[*].ipaddr')" 2001:db8::2 "second read $label: the address that was checked"
    lw_expect_eq "$(qmi_notify 0 '.ip6prefix[*]')" 2001:db8::2/64 "second read $label: the prefix that was checked"
    lw_expect_eq "$(qmi_notify 0 '.dns[*]')" "$(printf '%s\n%s' 2001:db8::53 2001:db8::54)" "second read $label: the DNS servers that were checked"
    lw_expect_eq "$(qmi_json_lines "$DYNAMIC" '@[*].name')" '' "second read $label: no IPv6 child"
done

# dhcpv6: the link at once, the modem's report is not read
qmi_fixture ipv6-only
qmi_run setup ipv4v6 '"dhcpv6":true' || lw_fail 'setup with dhcpv6 failed'
lw_expect_eq "$(qmi_child wwan_6 proto)" dhcpv6 'dhcpv6 child'
lw_expect_eq "$(qmi_count '--get-current-settings')" 0 'report not read'
lw_expect_eq "$(qmi_notify 0 '.ip6addr[*].ipaddr')" '' 'no address on the parent'

# static IPv4 (dhcp 0) keeps the stock path: the report of the IPv4 call on the parent
qmi_fixture owner-sim
qmi_run setup ipv4v6 '"dhcp":false' || lw_fail 'setup with static IPv4 failed'
lw_expect_eq "$(qmi_notify 0 '.ipaddr[*].ipaddr')" 192.0.2.2 'IPv4 address from the modem'
lw_expect_eq "$(qmi_json_lines "$DYNAMIC" '@[*].name')" '' 'no DHCP child with a static address'
echo ok
