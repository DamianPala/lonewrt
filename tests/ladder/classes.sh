# Class of one offline LTE-only cycle (R18, R18c, R21d): order sim, account, hang, unknown; the
# NETDEV WATCHDOG baseline counts only this boot, also across a log rotation; no DNS server in the
# lease means no DNS answer; an AT+CPIN? without a SIM answer is not sim.
# shellcheck source=tests/ladder/ladder.inc
. /fw/tests/ladder/ladder.inc

WD="kern.crit kernel: qmi_wwan wwan0: NETDEV WATCHDOG: transmit queue 0 timed out"
LEASE=$T/ifstatus/wwan_4.json

# fresh: a new boot well past the grace, no failure, nothing sent, LTE dead, operator DNS answering.
fresh() {
    boot_sim 1000
    rm -f "$STATE" "$T/at"/*
    : >/root/openwrt.log
    rm -f /root/openwrt.log.old
    printf '{"up":true,"dns-server":["192.0.2.53"]}\n' >"$LEASE"
    lw_net down down
    lw_dns up down
    echo 0 >"$T/net/txbump"
}

# class_after N: run N cycles and print the class in the state.
class_after() {
    runs "$1"
    state_get class
}

fresh
lw_expect_eq "$(class_after 1)" account "DNS answers, no watchdog"

fresh
yes "$WD" | head -n 5 >>/root/openwrt.log
lw_expect_eq "$(class_after 1)" account "watchdogs only from an earlier boot"

fresh
echo "$WD" | tee -a /root/openwrt.log >>"$T/logread"
lw_expect_eq "$(class_after 1)" hang "watchdog this boot before the first run"

fresh
lw_dns down down
echo 4 >"$T/net/txbump"
lw_expect_eq "$(class_after 1)" unknown "traffic out, DNS silent"
echo "$WD" | tee -a /root/openwrt.log >>"$T/logread"
lw_dns up down
lw_expect_eq "$(class_after 1)" hang "watchdog added this boot beats a DNS answer"

fresh
yes "$WD" | head -n 5 >>/root/openwrt.log
lw_dns down down
echo 4 >"$T/net/txbump"
lw_expect_eq "$(class_after 1)" unknown "before rotation"
mv /root/openwrt.log /root/openwrt.log.old
echo "$WD" >/root/openwrt.log
lw_dns up down
lw_expect_eq "$(class_after 1)" hang "watchdog in the log after rotation"

fresh
yes "$WD" | head -n 3 >>/root/openwrt.log
lw_dns down down
echo 4 >"$T/net/txbump"
runs 1
mv /root/openwrt.log /root/openwrt.log.old
echo "daemon.notice netifd: wwan is up" >/root/openwrt.log
lw_dns up down
lw_expect_eq "$(class_after 1)" account "rotation without a new watchdog"

fresh
printf '{"up":true,"dns-server":[]}\n' >"$LEASE"
echo 4 >"$T/net/txbump"
lw_expect_eq "$(class_after 1)" unknown "no DNS server in the lease"
echo 0 >"$T/net/txbump"
lw_expect_eq "$(class_after 1)" hang "fewer than 2 packets sent, pings included"

fresh
lw_dns down down
echo 1 >"$T/net/txbump"
lw_expect_eq "$(class_after 1)" unknown "2 pings of 1 packet each count as 2 sent"

fresh
lw_at_override 'AT+CPIN?' '+CPIN: SIM PIN'
lw_expect_eq "$(class_after 1)" sim "SIM PIN beats a DNS answer"

fresh
lw_at_override 'AT+CPIN?' '+CME ERROR: SIM not inserted'
lw_expect_eq "$(class_after 1)" sim "SIM not inserted"

fresh
lw_at_override 'AT+CPIN?' SILENT
lw_expect_eq "$(class_after 1)" account "silent AT+CPIN? is not sim"

fresh
lw_at_override 'AT+CPIN?' ERROR
lw_expect_eq "$(class_after 1)" account "bare ERROR is not sim"

fresh
lw_at_override 'AT+CPIN?' '+CPIN: SIM PIN'
lw_expect_eq "$(class_after 1)" sim "sim set"
lw_at_override 'AT+CPIN?' '+CPIN: READY'
lw_dns down down
lw_expect_eq "$(class_after 1)" sim "sim sticks to the end of the failure"

check_format
echo ok
