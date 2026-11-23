# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

qmi_fixture both-accepted
printf '1\n' >"$QMI_STATE/cid-limit"
rc=0
qmi_run setup ipv4v6 || rc=$?

lw_expect_eq "$rc" 1 'setup status'
lw_expect_eq "$(qmi_notify 3 '.error[*]')" NO_CID 'error on second allocation'
lw_expect_eq "$(qmi_notify 0 '["link-up"]')" '' 'parent update'
lw_expect_eq "$(qmi_arg_count --get-client-id)" 2 'allocation attempts'
lw_expect_eq "$(qmi_arg_count --start-network)" 1 'starts'
lw_expect_eq "$(cat "$QMI_STATE/calls/ipv4")" '17 -12345678' 'call before CID exhaustion'
echo ok
