# R11b: the AT port never appears -> one entry, no AT command; a modem that ignores the mode
# command -> 3 attempts, one entry, no "modem OK".
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/modem/helpers.inc
. /fw/tests/modem/helpers.inc
modem_setup 1,3,8,20,28,32

LW_AT_PORT=/dev/ttyUSB9 LW_MODEM_PORT_WAIT=2 sh /etc/rc.common /etc/init.d/lw-modem-mode start
wait_log "no AT port /dev/ttyUSB9 after 2 s" 10
wait_gone 'lw-modem-mode' 5
lw_expect_eq "$(count "$T/at-calls" AT+)" 0 "AT commands without a port"

: >"$T/syslog"
echo 0,0,0 >"$T/modem/zsnt"
lw_at_override 'AT+ZSNT=6,0,0' SILENT
sh /etc/rc.common /etc/init.d/lw-modem-mode start
wait_log "still differs after 3 attempts" 20
lw_expect_eq "$(count "$T/at-calls" 'AT+ZSNT=6,0,0')" 3 "mode set commands"
lw_expect_eq "$(count "$T/at-calls" 'AT+CPMS="ME","ME","ME"')" 3 "SMS store commands"
lw_expect_no_grep "$T/syslog" "modem OK"
lw_expect_grep "$T/syslog" "mode '0,0,0'"
wait_gone 'lw-modem-mode' 5
calls=$(wc -l <"$T/at-calls")
sleep 3
lw_expect_eq "$(wc -l <"$T/at-calls")" "$calls" "AT calls after giving up"
echo ok
