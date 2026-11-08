# Dead LTE, working EDGE (R16, R22 scenario, R18 "EDGE cycles keep the class"): ping and operator
# DNS silent on LTE, both up on EDGE. 250 cycles: 6 reboots also from online EDGE cycles, class hang,
# the router stays on EDGE.
# shellcheck source=tests/ladder/ladder.inc
. /fw/tests/ladder/ladder.inc

lw_net down up
lw_dns down up
runs 250

lw_expect_eq "$(reboot_runs)" "6 18 42 90 162 234" "runs with a reboot"
lw_expect_eq "$(wr_at 'EDGE enter')" "8 20 44 92 164 236" "EDGE entries"
lw_expect_eq "$(state_get class)" hang "class"
lw_expect_eq "$(state_get passive)" 1 "passive"
lw_expect_eq "$(state_get cycles)" 250 "online EDGE cycles count"
lw_expect_eq "$(mode_now)" edge "mode"
lw_expect_grep "$T/syslog" "wwan-recover: online on edge, failure goes on"
lw_expect_no_grep "$T/syslog" "failure over"
check_format
echo ok
