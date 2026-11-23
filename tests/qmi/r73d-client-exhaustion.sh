# R73d, R73e: the IPv6 client cannot be allocated after the IPv4 call is up (the modem's clients are
# used up, D5): the IPv4 call survives and is published with its signed handle, one DHCP child, zero
# failed starts; the IPv6 attempt is a refusal.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

qmi_fixture both-accepted
printf '1\n' >"$QMI_STATE/cid-limit"
qmi_run setup ipv4v6 || lw_fail 'setup with one client left failed'
lw_expect_eq "$(qmi_notify 3 '.error[*]')" '' 'failed starts'
lw_expect_eq "$(qmi_notify 0 '["link-up"]' | head -n 1)" true 'parent link'
lw_expect_eq "$(qmi_notify 0 .data.cid_4)" 17 'IPv4 CID'
lw_expect_eq "$(qmi_notify 0 .data.pdh_4)" -12345678 'surviving signed handle'
lw_expect_eq "$(qmi_notify 0 .data.cid_6)" '' 'IPv6 CID'
lw_expect_eq "$(qmi_json_lines "$DYNAMIC" '@[*].name')" wwan_4 'one DHCP child'
lw_expect_eq "$(qmi_arg_count --get-client-id)" 2 'allocation attempts'
lw_expect_eq "$(qmi_arg_count --start-network)" 1 'starts'
lw_expect_eq "$(cat "$QMI_STATE/calls/ipv4")" '17 -12345678 1' 'IPv4 call'
lw_expect_eq "$(ls "$QMI_STATE/clients")" 17 'clients'
echo ok
