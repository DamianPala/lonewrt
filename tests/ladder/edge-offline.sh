# EDGE without network after the limit (R23, R23a): 100 cycles with nothing online give no reboot;
# the LTE probe after 72 cycles on EDGE fails after 2 cycles and goes back to EDGE.
# shellcheck source=tests/ladder/ladder.inc
. /fw/tests/ladder/ladder.inc

lw_net down down
lw_dns down down
state_set cycles=300 reboots=6 class=hang passive=1 uptime=5000
boot
runs 100

lw_expect_eq "$(reboot_runs)" "" "no reboot"
lw_expect_eq "$(wr_at 'EDGE enter')" "302" "EDGE entry"
lw_expect_eq "$(wr_at 'LTE probe: ')" "374" "probe after 72 cycles on EDGE"
lw_expect_eq "$(wr_at 'EDGE back')" "376" "back to EDGE after 2 probe cycles"
lw_expect_eq "$(state_get cycles)" 400 "cycles"
lw_expect_eq "$(mode_now)" edge "mode"
check_format
echo ok
