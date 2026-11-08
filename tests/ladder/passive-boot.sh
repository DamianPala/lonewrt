# Boot in passive mode (R22a, R23a, R25, D32): after the limit with class hang, every boot enters
# EDGE exactly once, after the grace, without reboots; with class account it never does.
# shellcheck source=tests/ladder/ladder.inc
. /fw/tests/ladder/ladder.inc

lw_net down down
lw_dns down down
state_set cycles=300 reboots=6 class=hang passive=1 uptime=5000
boot
runs 20
lw_expect_eq "$(wr_at 'EDGE enter')" "302" "one EDGE entry after the first boot"
lw_expect_eq "$(mode_now)" edge "mode"

boot
runs 20
lw_expect_eq "$(wr_at 'EDGE enter')" "302 322" "one more EDGE entry after a power cut"
lw_expect_eq "$(reboot_runs)" "" "no reboot"
lw_expect_eq "$(wr_at 'LIMIT: ')" "" "no second LIMIT"

state_set cycles=300 reboots=2 class=account passive=1 uptime=5000
boot
runs 20
lw_expect_eq "$(wr_at 'EDGE enter')" "302 322" "no EDGE with class account"
lw_expect_eq "$(mode_now)" lte "mode with class account"
lw_expect_eq "$(reboot_runs)" "" "no reboot"
check_format
echo ok
