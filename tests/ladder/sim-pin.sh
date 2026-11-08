# Card locked by PIN (R18, R18d, D38): AT+CPIN? answers SIM PIN. Class sim works like account:
# reboots at 6 and 18 only, never EDGE; its entry quotes the answer and points to LuCI.
# shellcheck source=tests/ladder/ladder.inc
. /fw/tests/ladder/ladder.inc

lw_at_override 'AT+CPIN?' '+CPIN: SIM PIN'
lw_net down down
lw_dns down down
runs 250

lw_expect_eq "$(reboot_runs)" "6 18" "runs with a reboot"
lw_expect_eq "$(wr_at 'LIMIT: ')" "20" "LIMIT entry"
lw_expect_eq "$(wr_at 'EDGE')" "" "no EDGE"
lw_expect_eq "$(state_get class)" sim "class"
lw_expect_eq "$(wr_at 'SIM not ready')" "1" "sim entry once"
lw_expect_grep "$T/syslog" 'SIM not ready (AT+CPIN?: +CPIN: SIM PIN): enter the PIN in LuCI'
lw_expect_eq "$(mode_now)" lte "mode"
check_format
echo ok
