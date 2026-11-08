# R11a: mode and bands already right, so no set command for them; the SMS store command still goes.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/modem/helpers.inc
. /fw/tests/modem/helpers.inc
modem_setup 1,3,8,20,28,32
echo 6,0,0 >"$T/modem/zsnt"
echo 88080085 >"$T/modem/bands"

sh /etc/rc.common /etc/init.d/lw-modem-mode start
wait_log "modem OK" 20
lw_expect_no_grep "$T/at-calls" 'ZSNT='
lw_expect_no_grep "$T/at-calls" 'ZNLOCKBAND='
lw_expect_grep "$T/at-calls" 'AT+CPMS="ME","ME","ME"'
lw_expect_no_grep "$T/syslog" "setting"
lw_expect_no_grep "$T/syslog" "set to lte"
lw_expect_grep "$T/syslog" "modem OK: mode 6,0,0, bands 88080085, SMS store ME (attempt 1)"
echo ok
