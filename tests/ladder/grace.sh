# First 10 min after boot (R15, R16a, R17): no new failure, an ongoing one keeps counting without
# class, snapshot, EDGE or reboot; a threshold passed in the grace reboots in the first run after
# it; an online LTE-only cycle in the grace ends the failure.
# shellcheck source=tests/ladder/ladder.inc
. /fw/tests/ladder/ladder.inc

lw_net down down
lw_dns up down

boot
runs 1
[ ! -e "$STATE" ] || lw_fail "failure started in the grace"
[ ! -e "$SNAP" ] || lw_fail "snapshot in the grace"
lw_expect_grep "$T/syslog" "offline in the first 600s after boot (tx+0 rx+0); no failure started"

state_set cycles=5 reboots=0 class=none passive=0 uptime=4000
boot
runs 1
lw_expect_eq "$(state_get cycles)" 6 "grace counts an ongoing failure"
lw_expect_eq "$(state_get class)" none "no class in the grace"
[ ! -e "$SNAP" ] || lw_fail "snapshot in the grace"
lw_expect_eq "$(reboot_runs)" "" "no reboot in the grace at the threshold"
lw_expect_no_grep "$T/events" "^ifup"
runs 1
lw_expect_eq "$(reboot_runs)" "3" "threshold passed in the grace reboots right after it"
lw_expect_eq "$(wr_at 'REBOOT ')" "7" "reboot at cycle 7"
lw_expect_eq "$(state_get class)" account "class after the grace"

state_set cycles=10 reboots=1 class=hang passive=0 uptime=4000
boot
runs 1
lw_expect_eq "$(wr_at 'EDGE enter')" "" "no EDGE in the grace"
boot
lw_net up down
runs 1
lw_expect_eq "$(wr_at 'online on LTE, failure over')" "11" "online in the grace ends the failure"
[ ! -e "$STATE" ] || lw_fail "state left after the failure ended"
check_format
echo ok
