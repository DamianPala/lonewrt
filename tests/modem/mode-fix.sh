# R10, R11, R12: after a test left the modem in auto mode with B7, one boot brings back LTE-only,
# the profile bands and the ME store, over /dev/ttyUSB2 only, and logs "modem OK".
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/modem/helpers.inc
. /fw/tests/modem/helpers.inc
modem_setup 1,3,8,20,28,32
echo 0,0,0 >"$T/modem/zsnt"
echo 880800C5 >"$T/modem/bands"
uci set network.wwan.modes=all
uci commit network

start=$(sed -n 's/^START=//p' /etc/init.d/lw-modem-mode)
[ "$start" -lt 20 ] || lw_fail "START=$start does not run before netifd (20)"

export LW_MODEM_SETTLE=3
t0=$(date +%s)
sh /etc/rc.common /etc/init.d/lw-modem-mode start
[ $(($(date +%s) - t0)) -le 1 ] || lw_fail "init script waited for the modem"
# R10: the uci part is done before the init script returns, so netifd's first ifup asks for LTE
lw_expect_eq "$(uci get network.wwan.modes)" lte "network.wwan.modes"
lw_expect_grep "$T/syslog" "lw-modem-mode: network.wwan.modes 'all' set to lte"
# R11: no AT command before the settle delay after the port appeared
sleep 1
lw_expect_eq "$(count "$T/at-calls" AT+)" 0 "AT commands during the settle delay"

wait_log "modem OK" 20
lw_expect_eq "$(cat "$T/modem/zsnt")" 6,0,0 "ZSNT"
lw_expect_eq "$(cat "$T/modem/bands")" 88080085 "band mask"
lw_expect_eq "$(cat "$T/modem/cpms")" '"ME","ME","ME"' "SMS stores"
lw_expect_grep "$T/at-calls" 'AT+ZSNT=6,0,0'
lw_expect_grep "$T/at-calls" 'AT+ZNLOCKBAND=1,0,88080085,0'
lw_expect_grep "$T/syslog" "lw-modem-mode: mode '0,0,0', setting LTE-only"
lw_expect_grep "$T/syslog" "lw-modem-mode: band mask '880800C5', setting 88080085"
# R12: every AT command on the scripts' port
lw_expect_eq "$(grep -cv '^/dev/ttyUSB2 at ' "$T/at-calls" || :)" 0 "AT calls off /dev/ttyUSB2"
wait_gone 'lw-modem-mode' 5
no_orphans
echo ok
