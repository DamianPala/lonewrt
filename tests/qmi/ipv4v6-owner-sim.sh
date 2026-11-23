# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

qmi_fixture owner-sim
rc=0
qmi_run setup ipv4v6 || rc=$?

# The 2026-11-23 spike saw IPv4 start and IPv6 return "Call failed" under IPV4V6.
# The current handler returns before handing IPv4's CID and handle to netifd.
lw_expect_eq "$rc" 1 'setup status'
lw_expect_eq "$(qmi_notify 3 '.error[*]')" CALL_FAILED 'parent error'
lw_expect_eq "$(qmi_notify 0 '["link-up"]')" '' 'parent update'
lw_expect_eq "$(qmi_json_lines "$DYNAMIC" '@[*].name')" '' 'children'
lw_expect_eq "$(qmi_arg_count --start-network)" 2 'starts'
lw_expect_eq "$(qmi_arg_count --release-client-id)" 1 'released IPv6 client'
lw_expect_eq "$(ls "$QMI_STATE/clients")" 17 'unpublished IPv4 client'
lw_expect_eq "$(ls "$QMI_STATE/calls")" ipv4 'unpublished call'
echo ok
