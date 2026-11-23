# R73d, R73a: every step refused gives one failed start per start, CALL_FAILED, no published data, no
# client and no call left, and the stock log line; two starts in a row give two failures (the
# second one makes the Auto-APN table eligible, R13b, which tests/qmi/r73d-auto-apn.sh traces).
# Repeated failure to get a client ends the steps of that start (R73d).
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

qmi_fixture both-refused
out=$(qmi_run setup ipv4v6) && lw_fail 'a start with every step refused succeeded'
lw_expect_eq "$(qmi_notify 3 '.error[*]')" CALL_FAILED 'one failed start'
lw_expect_eq "$(qmi_notify 0 '["link-up"]')" '' 'parent update'
lw_expect_eq "$(qmi_json_lines "$DYNAMIC" '@[*].name')" '' 'children'
lw_expect_eq "$(qmi_arg_count --start-network)" 4 'starts: two in step 1, one in each of the others'
lw_expect_eq "$(qmi_arg_count --get-client-id)" 4 'clients taken'
lw_expect_eq "$(qmi_arg_count --release-client-id)" 4 'clients released'
qmi_modem_clean 'after the failed start'
lw_expect_eq "$(printf '%s\n' "$out" | grep -c 'Unable to connect')" 1 'one failure line at the info level'
lw_expect_eq "$(qmi_syslog)" '' 'lines at the info level'

# a second start in a row: one more failure, each start with its own error
qmi_run setup ipv4v6 >/dev/null && lw_fail 'the second start succeeded'
lw_expect_eq "$(qmi_notify 3 '.error[*]' | tr '\n' ' ')" 'CALL_FAILED CALL_FAILED ' 'two failed starts'

# forced IPv4 refused: the stock line, one failure
qmi_fixture both-refused
out=$(qmi_run setup ipv4) && lw_fail 'forced IPv4 with a refusal succeeded'
lw_expect_eq "$(printf '%s\n' "$out" | tail -n 1)" 'Unable to connect IPv4' 'stock line of forced IPv4'
lw_expect_eq "$(qmi_notify 3 '.error[*]')" CALL_FAILED 'forced IPv4 failed start'

# no client at all: two failed allocations end the steps, NO_CID as the stock handler says
qmi_fixture both-accepted
printf '0\n' >"$QMI_STATE/cid-limit"
qmi_run setup ipv4v6 >/dev/null && lw_fail 'a start without clients succeeded'
lw_expect_eq "$(qmi_notify 3 '.error[*]')" NO_CID 'error without a client'
lw_expect_eq "$(qmi_arg_count --get-client-id)" 2 'allocation attempts before the steps end'
lw_expect_eq "$(qmi_arg_count --start-network)" 0 'starts'
lw_expect_eq "$(qmi_arg_count --modify-profile)" 2 'profile writes: the first step and the rollback'
lw_expect_eq "$(cat "$QMI_STATE/profile.pdp")" ipv4 'profile type back to the one before the start'
echo ok
