# R38b: a failing notification service (bad token, Telegram unreachable or hanging, killed) never
# reboots, never touches the modem mode or wwan, and delays another script's AT command by at most
# one short command. The other script here is an lw_at caller like wwan-recover's, run while the
# service loop runs. R27, R37a: the notification code sends only the balance query of the operator preset and changes nothing.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup 7.50
# shellcheck source=src/files/usr/lib/lw/common.sh
. /usr/lib/lw/common.sh
export LW_NOTIFY_CLOCK=/proc/uptime LW_NOTIFY_POLL=1 LW_NOTIFY_LONGPOLL=1
sms_in 0 +38200000001 '11/07/26 10:00:00' 'old'

# other_script: 8 AT reads 1 s apart while the service runs; each must answer within 3 s
other_script() {
    _i=0
    while [ "$_i" -lt 8 ]; do
        _t0=$(date +%s)
        _r=$(lw_at 10 'AT+ZSNT?') || lw_fail "lw_at failed next to the service ($1)"
        lw_expect_eq "$_r" "+ZSNT: 6,0,0" "modem mode next to the service ($1)"
        [ "$(elapsed_since "$_t0")" -le 3 ] || lw_fail "lw_at waited $(elapsed_since "$_t0") s ($1)"
        sleep 1
        _i=$((_i + 1))
    done
}

for fault in token down hang; do
    case $fault in
        token) echo 'other:token' >"$G/token" ;;
        down) echo down >"$G/net" ;;
        hang) echo hang >"$G/net" ;;
    esac
    lw-notify run </dev/null >/dev/null 2>&1 &
    svc=$!
    sleep 1
    sms_in 1 +38200000002 '11/07/26 10:01:00' "during $fault"
    tg_push "$TG_CHAT" /balance
    other_script "$fault"
    kill -9 "$svc"
    # a killed service leaves the lock free within one short command
    sleep 3
    flock -n /tmp/lw-at.lock true || lw_fail "AT lock still held after kill -9 ($fault)"
    lw_expect_grep "$T/syslog" "lw-notify: Telegram unreachable"
    echo "$TG_TOKEN" >"$G/token"
    echo up >"$G/net"
    rm -f "$T/modem/sms/1.json"
    # the link state outlives the killed process, so the next fault would log nothing new
    rm -f /tmp/lw-notify/down /tmp/lw-notify/fail_since
    : >"$T/syslog"
done
sleep 4
no_orphans
lw_expect_eq "$(cat "$T/events")" "" "reboot, ifup or ifdown by the notification service"
lw_expect_eq "$(cat "$T/modem/zsnt")" 6,0,0 "modem mode"
lw_expect_eq "$(uci get network.wwan.modes)" lte "network.wwan.modes"
lw_expect_eq "$(cat "$T/sms-sent" 2>/dev/null)" "" "SMS sent for a command from before the start"

# static: no interface or modem change, and the only SMS are the balance query of the preset and the replies to SMS
# admins (R27, R46), both through nt_sms_send; the one restart command is the line `reboot` of
# nt_rb_go in reboot.sh, which the tap handler of R45 and the SMS command of R46b call
N="/fw/src/files/usr/sbin/lw-notify /fw/src/files/usr/lib/lw/notify.sh
/fw/src/files/etc/init.d/lw-notify /fw/src/files/etc/hotplug.d/iface/95-lw-notify
/fw/src/files/usr/lib/lw/speedtest.sh /fw/src/files/usr/lib/lw/devices.sh
/fw/src/files/usr/lib/lw/reboot.sh /fw/src/files/usr/lib/lw/smsctl.sh
/fw/src/files/usr/lib/lw/operators.sh /fw/src/files/usr/lib/lw/multipart.sh
/fw/src/files/usr/sbin/lw-heartbeat"
# (the hotplug's test of "$ACTION" = ifup is the only allowed mention of ifup)
# shellcheck disable=SC2016  # literal $ACTION and $LW_AT_PORT in the patterns below
# shellcheck disable=SC2086  # word splitting of the file list is intended
! grep -nE '^[^#]*\b(ifup|ifdown|uqmi|uci (set|commit|delete))\b|AT\+[A-Z]+=' $N |
    grep -v '"\$ACTION" = ifup' || lw_fail "the notification code changes the router or the modem"
# shellcheck disable=SC2086
restarts=$(grep -nE '^[^#]*\b(reboot|poweroff|halt)\b' $N |
    grep -vE ':[0-9]+:.*(/reboot|nt_reboot|reboot\.sh|reboot_req|NT_DIR/reboot|nt_rb_|SC_OPENINGS=|commands: status, reboot|: reboot not done)|:[0-9]+: *reboot\)|= reboot \]' || :)
case $restarts in
    /fw/src/files/usr/lib/lw/reboot.sh:*:'    reboot') ;;
    *) lw_fail "restart commands in the notification code: $restarts" ;;
esac
lw_expect_eq "$(printf '%s\n' "$restarts" | wc -l | tr -d ' ')" 1 "restart commands in the notification code"
hits=$(grep -rnE 'sms_tool[^|;]* (send|ussd)|AT\+CMGS|AT\+CUSD' /fw/src/files)
lw_expect_eq "$(printf '%s\n' "$hits" | wc -l)" 1 "SMS or USSD sends in the image"
# shellcheck disable=SC2016  # literal $LW_AT_PORT of the source line
case $hits in
    /fw/src/files/usr/lib/lw/notify.sh:*'sms_tool -d "$LW_AT_PORT" send "${1#+}" "$2"'*) ;;
    *) lw_fail "unexpected send: $hits" ;;
esac
# the callers of nt_sms_send: the balance query of the operator preset (R47), and the reply to the
# sender of an admin's command
callers=$(grep -rnE '^[^#]*\bnt_sms_send\b' /fw/src/files | grep -v 'nt_sms_send() {' |
    sed 's/^[^:]*:[0-9]*: *//' | sort)
# shellcheck disable=SC2016
lw_expect_eq "$callers" 'nt_sms_send "$1" "$(sc_clean "$2")" && return 0
nt_sms_send "$NT_P_QTO" "$NT_P_QTEXT"' "callers of nt_sms_send"
echo ok
