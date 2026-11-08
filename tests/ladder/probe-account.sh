# LTE probe that finds an exhausted package (R18b, R23, R25, D41): the probe cycles give class
# account, so the router does not go back to EDGE and waits on LTE; after a top-up the next online
# cycle, confirmed by AT+ZSNT?, ends the failure.
# shellcheck source=tests/ladder/ladder.inc
. /fw/tests/ladder/ladder.inc

lw_net down down
lw_dns down down
state_set cycles=300 reboots=6 class=hang passive=1 uptime=5000
boot
runs 74
lw_expect_eq "$(wr_at 'LTE probe: ')" "374" "probe"
lw_dns up down
echo 4 >"$T/net/txbump"
runs 100

lw_expect_eq "$(state_get class)" account "class from the probe"
lw_expect_eq "$(wr_at 'EDGE back')" "" "no EDGE back"
lw_expect_eq "$(wr_at 'LTE probe failed with class account')" "376" "stay entry once"
lw_expect_eq "$(wr_at 'LTE probe: ')" "374" "no further probes"
lw_expect_eq "$(mode_now)" lte "mode"
lw_expect_eq "$(reboot_runs)" "" "no reboot"

lw_net up down
runs 1
lw_expect_eq "$(wr_at 'online on LTE, failure over')" "474" "top-up ends the failure"
[ ! -e "$STATE" ] || lw_fail "state left after the failure ended"
check_format
echo ok
