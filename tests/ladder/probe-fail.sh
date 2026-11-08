# Failed LTE probes after the limit (R18b, R23, D41): LTE stays dead, each probe goes back to EDGE
# after 2 cycles, probes repeat every 72 cycles on EDGE, the probe cycles set the class (hang).
# shellcheck source=tests/ladder/ladder.inc
. /fw/tests/ladder/ladder.inc

lw_net down down
lw_dns down down
state_set cycles=300 reboots=6 class=unknown passive=1 uptime=5000
boot
runs 160

lw_expect_eq "$(wr_at 'LTE probe: ')" "374 448" "probes"
lw_expect_eq "$(wr_at 'EDGE back')" "376 450" "back to EDGE"
lw_expect_eq "$(state_get class)" hang "class from the probe cycles"
lw_expect_eq "$(reboot_runs)" "" "no reboot"
lw_expect_eq "$(mode_now)" edge "mode"
lw_expect_eq "$(cat "$T/modem/zsnt")" 0,0,0 "modem back in auto mode"
check_format
echo ok
