# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

qmi_fixture owner-sim
qmi_run setup ipv4 || lw_fail 'IPv4 setup failed'

lw_expect_eq "$(qmi_notify 0 '["link-up"]')" true 'parent link'
lw_expect_eq "$(qmi_notify 0 .ifname)" wwan0 'parent device'
lw_expect_eq "$(qmi_notify 0 .data.cid_4)" 17 'IPv4 CID'
lw_expect_eq "$(qmi_notify 0 .data.pdh_4)" -12345678 'signed IPv4 PDH'
lw_expect_eq "$(qmi_notify 0 .data.cid_6)" '' 'IPv6 CID'
lw_expect_eq "$(qmi_notify 3 '.error[*]')" '' 'setup errors'
lw_expect_eq "$(qmi_child wwan_4 proto)" dhcp 'IPv4 child protocol'
lw_expect_eq "$(qmi_child wwan_4 ifname)" @wwan 'IPv4 child parent'
lw_expect_eq "$(qmi_json_lines "$DYNAMIC" '@[*].name')" wwan_4 'children'
lw_expect_eq "$(cat "$QMI_STATE/profile.pdp")" ipv4 'stored PDP type'
lw_expect_eq "$(cat "$QMI_STATE/profile.apn")" internet.example 'stored APN'
lw_expect_eq "$(ls "$QMI_STATE/clients")" 17 'live clients'
lw_expect_eq "$(cat "$QMI_STATE/clients/17")" ipv4 'selected family'
lw_expect_eq "$(ls "$QMI_STATE/calls")" ipv4 'active families'
lw_expect_eq "$(qmi_arg_count --get-client-id)" 1 'client allocations'
lw_expect_eq "$(qmi_arg_count --start-network)" 1 'starts'
# Stock setup always sweeps stale IPv6 calls. It makes no other IPv6 request in this case.
lw_expect_eq "$(qmi_arg_count ipv6)" 1 'IPv6 references (initial sweep)'
echo ok
