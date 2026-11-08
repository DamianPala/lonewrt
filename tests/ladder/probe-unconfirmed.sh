# LTE probe that is online but not in LTE-only mode (R23): the modem ignores AT+ZSNT=6,0,0 and
# stays in auto mode on a working EDGE. Pings answer, AT+ZSNT? does not confirm mode 6, so the
# failure goes on and the probe goes back to EDGE after 2 cycles.
# shellcheck source=tests/ladder/ladder.inc
. /fw/tests/ladder/ladder.inc

lw_net down up
lw_dns down up
state_set cycles=300 reboots=6 class=hang passive=1 uptime=5000
boot
runs 2
lw_expect_eq "$(mode_now)" edge "on EDGE"
lw_at_override 'AT+ZSNT=6,0,0' SILENT
runs 74

lw_expect_eq "$(wr_at 'LTE probe: ')" "374" "probe"
lw_expect_eq "$(wr_at 'EDGE back')" "376" "back to EDGE"
lw_expect_grep "$T/syslog" "LTE probe online but AT+ZSNT? does not confirm LTE-only mode"
lw_expect_no_grep "$T/syslog" "failure over"
[ -e "$STATE" ] || lw_fail "the failure must go on"
check_format
echo ok
