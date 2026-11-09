# Scenario A, modem hang (R16, R18, R19, R20, R22, R22a, R24): a NETDEV WATCHDOG line every cycle,
# nothing goes out, LTE and EDGE dead. Reboots at 6/18/42/90/162/234, EDGE in the first run after
# the boot grace behind every reboot, class hang, LIMIT, passive mode on EDGE.
# shellcheck source=tests/ladder/ladder.inc
. /fw/tests/ladder/ladder.inc

before_run() {
    echo "Mon Nov  9 10:00:18 2026 kern.err kernel: [  123.456789] NETDEV WATCHDOG: wwan0 (qmi_wwan): transmit queue 0 timed out" |
        tee -a /root/openwrt.log >>"$T/logread"
}
lw_net down down
lw_dns down down
runs 250

lw_expect_eq "$(reboot_runs)" "6 18 42 90 162 234" "runs with a reboot"
lw_expect_eq "$(wr_at 'REBOOT ')" "6 18 42 90 162 234" "REBOOT entries"
lw_expect_eq "$(wr_at 'EDGE enter')" "8 20 44 92 164 236" "EDGE entries"
lw_expect_eq "$(wr_at 'LIMIT: ')" "236" "LIMIT entry"
lw_expect_eq "$(wr_at 'LTE probe')" "" "no LTE probe before 72 cycles on EDGE"
lw_expect_eq "$(state_get cycles)" 250 "cycles"
lw_expect_eq "$(state_get reboots)" 6 "reboots"
lw_expect_eq "$(state_get class)" hang "class"
lw_expect_eq "$(state_get passive)" 1 "passive"
lw_expect_eq "$(mode_now)" edge "mode at the end"
lw_expect_eq "$(cat "$T/modem/zsnt")" 0,0,0 "modem in auto mode"
lw_expect_eq "$(uci get network.wwan.modes)" all "uci modes"
lw_expect_eq "$(count '^=== failure start cycle=1 ' "$SNAP")" 1 "snapshot start entry"
lw_expect_eq "$(count '^=== reboot ' "$SNAP")" 6 "snapshot reboot entries"
lw_expect_eq "$(count '^=== limit cycle=236 ' "$SNAP")" 1 "snapshot limit entry"
lw_expect_grep "$T/syslog" "lw-fallback: switched to edge"
check_format
echo ok
