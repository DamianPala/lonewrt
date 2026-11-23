# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

qmi_fixture owner-sim
qmi_run setup ipv4 || lw_fail 'IPv4 setup failed'
lw_expect_eq "$(cat "$QMI_STATE/calls/ipv4")" '17 -12345678' 'active IPv4 call'

qmi_run teardown ipv4 || lw_fail 'IPv4 teardown failed'
lw_expect_eq "$(qmi_notify 0 '["link-up"]' | tail -n 1)" false 'parent link after teardown'
lw_expect_eq "$(qmi_arg_count -12345678)" 1 'stop request with the published signed handle'
lw_expect_eq "$(qmi_arg_count --release-client-id)" 1 'client releases'
lw_expect_eq "$(ls "$QMI_STATE/clients")" '' 'remaining clients'
lw_expect_eq "$(ls "$QMI_STATE/calls")" '' 'remaining calls'
lw_expect_eq "$(cat "$QMI_STATE/profile.pdp")" ipv4 'profile persists after teardown'
echo ok
