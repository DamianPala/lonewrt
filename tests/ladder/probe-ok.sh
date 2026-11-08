# Successful LTE probe after the limit (R15, R23): the probe switches to LTE-only mode, LTE is back,
# AT+ZSNT? confirms mode 6 and the failure ends; the router stays on LTE afterwards.
# shellcheck source=tests/ladder/ladder.inc
. /fw/tests/ladder/ladder.inc

lw_net down down
lw_dns down down
state_set cycles=300 reboots=6 class=hang passive=1 uptime=5000
boot
runs 74
lw_expect_eq "$(wr_at 'LTE probe: ')" "374" "probe"
lw_expect_eq "$(mode_now)" lte "mode during the probe"
lw_expect_eq "$(cat "$T/modem/zsnt")" 6,0,0 "modem LTE-only during the probe"
lw_expect_grep "$T/syslog" "probe: 72 cycles on EDGE, trying LTE-only mode cycle=374 reboots=6 class=hang mode=edge"

lw_net up down
runs 1
lw_expect_eq "$(wr_at 'online on LTE, failure over')" "374" "failure over"
lw_expect_grep "$T/syslog" "failure over after 374 cycles and 6 reboots, LTE probe confirmed by AT+ZSNT?"
[ ! -e "$STATE" ] || lw_fail "state left after the failure ended"
runs 10
[ ! -e "$STATE" ] || lw_fail "state written while online"
lw_expect_eq "$(mode_now)" lte "mode after the probe"
lw_expect_eq "$(wr_at 'EDGE back')" "" "no EDGE back"
touch "$T/net/partial"
runs 1
[ ! -e "$STATE" ] || lw_fail "one reply of two read as offline"
check_format
echo ok
