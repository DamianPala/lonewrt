# R73b, R73c, R77a: a SIM that grants IPv4 and refuses IPv6 (the owner's) comes up on IPv4 after one
# refused IPv6 call: the signed IPv4 handle is published, one DHCP child, no failed start, the IPv6
# client released. At the info level the log is the one of forced IPv4; at the debug level it has
# one line per start that IPv6 was refused. A start remembers no refusal (R73c).
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

qmi_fixture owner-sim
qmi_run setup ipv4v6 || lw_fail 'auto setup on the IPv4-only SIM failed'
lw_expect_eq "$(qmi_notify 0 '["link-up"]')" true 'parent link'
lw_expect_eq "$(qmi_notify 0 .data.cid_4)" 17 'IPv4 CID'
lw_expect_eq "$(qmi_notify 0 .data.pdh_4)" -12345678 'surviving signed handle'
lw_expect_eq "$(qmi_notify 0 .data.cid_6)" '' 'IPv6 CID'
lw_expect_eq "$(qmi_notify 0 .data.pdh_6)" '' 'IPv6 handle'
lw_expect_eq "$(qmi_notify 3 '.error[*]')" '' 'failed starts'
lw_expect_eq "$(qmi_json_lines "$DYNAMIC" '@[*].name')" wwan_4 'one DHCP child'
lw_expect_eq "$(qmi_child wwan_4 proto)" dhcp 'IPv4 child protocol'
lw_expect_eq "$(qmi_arg_count --start-network)" 2 'starts: IPv4 and the refused IPv6'
lw_expect_eq "$(qmi_arg_count --release-client-id)" 1 'released IPv6 client'
lw_expect_eq "$(ls "$QMI_STATE/clients")" 17 'live clients'
lw_expect_eq "$(ls "$QMI_STATE/calls")" ipv4 'live calls'
lw_expect_eq "$(cat "$QMI_STATE/profile.pdp")" ipv4v6 'profile type of the step'
lw_expect_eq "$(qmi_syslog)" '' 'lines at the info level'

qmi_ifdown ipv4v6
qmi_modem_clean 'after teardown'

# debug level: one line that IPv6 was refused
qmi_debug
qmi_run setup ipv4v6 || lw_fail 'second auto setup failed'
lw_expect_eq "$(qmi_syslog | grep -c 'IPv6 refused')" 1 'lines about the refused IPv6'
lw_expect_eq "$(qmi_syslog | grep -c 'IPv4 refused')" 0 'lines about a refused IPv4'
grep -q '^daemon.debug lw-qmi: ' "$LW_TEST/syslog.prio" || lw_fail 'the line is not at daemon.debug'
qmi_ifdown ipv4v6

# R73c: the operator grants IPv6 at the next start, and the start asks again
cp "$QMI_DIR/scenarios/both-accepted" "$QMI_STATE/scenario"
qmi_run setup ipv4v6 || lw_fail 'third auto setup failed'
lw_expect_eq "$(qmi_notify 0 .data.cid_6 | tail -n 1)" 22 'IPv6 CID of the third session'
lw_expect_eq "$(ls "$QMI_STATE/calls" | tr '\n' ' ')" 'ipv4 ipv6 ' 'dual stack at the next start'
echo ok
