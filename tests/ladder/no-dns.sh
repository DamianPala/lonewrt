# Scenario B2 (R18, R18c, R16, R22): pings fail, traffic goes out, the operator DNS is silent too.
# Class unknown (treated as hang): the full ladder and EDGE behind every reboot.
# shellcheck source=tests/ladder/ladder.inc
. /fw/tests/ladder/ladder.inc

lw_net down down
lw_dns down down
echo 4 >"$T/net/txbump"
runs 250

lw_expect_eq "$(reboot_runs)" "6 18 42 90 162 234" "runs with a reboot"
lw_expect_eq "$(wr_at 'EDGE enter')" "8 20 44 92 164 236" "EDGE entries"
lw_expect_eq "$(wr_at 'LIMIT: ')" "236" "LIMIT entry"
lw_expect_eq "$(state_get class)" unknown "class"
lw_expect_eq "$(mode_now)" edge "mode"
check_format
echo ok
