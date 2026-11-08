# R27: no script of the image sends SMS or USSD except the preset's balance query and the replies
# to admins. R12c: none runs uqmi. R12: none uses the LuCI port or modemband.sh. Checked on the
# modem scripts and, for R27, on the whole overlay.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
F=/fw/src/files
MINE="$F/etc/init.d/lw-modem-mode $F/etc/hotplug.d/iface/99-auto-apn-at $F/usr/lib/lw/lw-apn
$F/usr/sbin/lw-sms-clean $F/usr/sbin/lw-siglog"
# shellcheck disable=SC2086  # word splitting of the file list is intended
for f in $MINE; do [ -f "$f" ] || lw_fail "missing $f"; done
# R27 (D47, R46): the only SMS of the image are RACUN to 1466 and the replies to SMS admins; both go
# through the one send line of nt_sms_send in the notification library (tests/notify/isolation.sh
# lists its callers)
hits=$(grep -rnE 'sms_tool[^|;]* (send|ussd)|AT\+CMGS|AT\+CUSD' "$F" || :)
# shellcheck disable=SC2016  # literal $LW_AT_PORT of the source line
send=$(grep -Hn 'sms_tool -d "$LW_AT_PORT" send "${1#+}" "$2"' "$F/usr/lib/lw/notify.sh" || :)
[ -z "$hits" ] || [ "$hits" = "$send" ] || lw_fail "R27: send or USSD: $hits"
# shellcheck disable=SC2086
! grep -nE '^[^#]*\buqmi\b' $MINE || lw_fail "R12c: uqmi"
# shellcheck disable=SC2086
! grep -nE '^[^#]*(ttyUSB1|modemband\.sh)' $MINE || lw_fail "R12: LuCI port or modemband.sh"
echo ok
