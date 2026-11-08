# R11c: a profile without bands never touches the modem's bands; a malformed list is logged and
# treated the same way.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/modem/helpers.inc
. /fw/tests/modem/helpers.inc
modem_setup ''
echo 0,0,0 >"$T/modem/zsnt"
echo 880800C5 >"$T/modem/bands"

sh /etc/rc.common /etc/init.d/lw-modem-mode start
wait_log "modem OK: mode 6,0,0, bands untouched" 20
lw_expect_no_grep "$T/at-calls" 'ZNLOCKBAND'
lw_expect_eq "$(cat "$T/modem/bands")" 880800C5 "band mask"
wait_gone 'lw-modem-mode' 5

: >"$T/syslog"
uci set lonewrt.modem.bands='1,3,99'
uci commit lonewrt
sh /etc/rc.common /etc/init.d/lw-modem-mode start
wait_log "modem OK" 20
lw_expect_grep "$T/syslog" "lonewrt.modem.bands '1,3,99' is not a list of bands"
lw_expect_no_grep "$T/at-calls" 'ZNLOCKBAND'
wait_gone 'lw-modem-mode' 5

# the mask arithmetic itself: bit n-1 is band n, leading zeros are not octal
# (rc.common sources the init script the same way)
# shellcheck source=src/files/etc/init.d/lw-modem-mode
. /etc/init.d/lw-modem-mode
lw_expect_eq "$(lwmm_mask 1,3,8,20,28,32)" 88080085 "mask"
lw_expect_eq "$(lwmm_mask '08, 20')" 80080 "mask with spaces and zeros"
lw_expect_eq "$(lwmm_mask 64)" 8000000000000000 "band 64"
! lwmm_mask 0 >/dev/null || lw_fail "band 0 accepted"
! lwmm_mask 65 >/dev/null || lw_fail "band 65 accepted"
echo ok
