# Scenario B, package exhausted (R18, R18a, R18c, R19, R25, D40): pings fail, the operator DNS
# answers, traffic goes out. Only reboots at 6 and 18, never EDGE, class account in the state.
# A cycle with DNS silent and nothing sent before the class is set gives hang for one cycle only;
# the same glitch after it does not move the sticky account.
# shellcheck source=tests/ladder/ladder.inc
. /fw/tests/ladder/ladder.inc

before_run() {
    case $run in
        1 | 10)
            lw_dns down down
            echo 0 >"$T/net/txbump"
            ;;
        *)
            lw_dns up down
            echo 4 >"$T/net/txbump"
            ;;
    esac
}
lw_net down down
runs 1
lw_expect_eq "$(state_get class)" hang "class after a glitch cycle"
runs 249

lw_expect_eq "$(reboot_runs)" "6 18" "runs with a reboot"
lw_expect_eq "$(wr_at 'LIMIT: ')" "20" "LIMIT entry"
lw_expect_eq "$(wr_at 'EDGE')" "" "no EDGE"
lw_expect_eq "$(state_get class)" account "class"
lw_expect_eq "$(state_get passive)" 1 "passive"
lw_expect_eq "$(state_get reboots)" 2 "reboots"
lw_expect_eq "$(mode_now)" lte "mode"
lw_expect_eq "$(cat "$T/modem/zsnt")" 6,0,0 "modem LTE-only"
lw_expect_eq "$(wr_at 'operator DNS answers but no data')" "2" "account entry once"
lw_expect_no_grep "$T/events" "^ifup"
check_format
echo ok
