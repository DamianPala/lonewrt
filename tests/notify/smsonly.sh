# R46d: SMS control without the Telegram keys. The service starts with lonewrt.notify.sms_admins alone
# (and not without it); it answers commands and restarts on REBOOT, but never calls the Bot API,
# never queues a message for the chat (nothing may pile up there) and writes no note for a chat.
# The Telegram parts of the commands (flush, balance, speedtest-run, the wwan hotplug) stay idle.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup ''
ADMIN=+48000000001
HELP='Home router commands: status, reboot'
uci -q delete lonewrt.notify.token
uci -q delete lonewrt.notify.chat
uci -q commit lonewrt
lw_net up down

# procd stand-ins: record what the init script asks for
procd_open_instance() { echo open >>"$T/procd"; }
procd_set_param() { echo "$*" >>"$T/procd"; }
procd_close_instance() { echo close >>"$T/procd"; }
init_start() {
    : >"$T/procd"
    (
        # shellcheck source=src/files/etc/init.d/lw-notify
        . /etc/init.d/lw-notify
        start_service
    )
}

# no keys and no admins: no instance; with admins alone: the instance
admins_set ''
init_start
lw_expect_eq "$(cat "$T/procd")" "" "procd calls without token, chat and admins"
admins_set "$ADMIN"
init_start
lw_expect_eq "$(cat "$T/procd")" "open
command /usr/sbin/lw-notify run
respawn 3600 5 0
close" "procd instance with SMS admins alone"
# one key of the two and admins: the instance, and the one syslog entry about the other part
uci -q set lonewrt.notify.token="$TG_TOKEN"
uci -q commit lonewrt
: >/etc/lw-notify.partial
: >"$T/syslog"
init_start
lw_expect_eq "$(grep -c 'lw-notify: notifications off: the profile sets only one' "$T/syslog")" 1 "partial-key entry"
lw_expect_eq "$(cat "$T/procd")" "open
command /usr/sbin/lw-notify run
respawn 3600 5 0
close" "procd instance with one key and admins"
uci -q delete lonewrt.notify.token
uci -q commit lonewrt

# --- the passes: the first one records the store, then a command is answered
sms_in 0 1466 '11/07/26 11:05:00' 'Imate: 0.31 do 05.01.; '
sms_in 1 +38200000005 '11/07/26 10:00:00' 'a message from before'
passes 2
lw_uptime_set 1140
sig_line -86dBm 4.6dB
sms_cmd 48000000001 'status'
lw_expect_eq "$(sms_out)" 1 "reply to STATUS without Telegram"
lw_expect_eq "$(sms_to 1)" "${ADMIN#+}" "reply goes to the sender"
case $(sms_body 1) in
    'Home router: internet OK (4G+), signal fair. On since '*'. Balance 0.31 EUR (7 Nov).') ;;
    *) lw_fail "STATUS text: $(sms_body 1)" ;;
esac
sms_cmd +38200000005 'STATUS'
sms_cmd 48000000001 'what'
lw_expect_eq "$(sms_out)" 2 "replies after a message from a number off the list and a HELP"
lw_expect_eq "$(sms_body 2)" "$HELP" "HELP text"

# nothing for a chat: no API call, no queue, no note, no state of the chat side
[ ! -e "$G/calls" ] || lw_fail "the Bot API was called: $(cat "$G/calls")"
[ -z "$(find /etc/lw-notify/queue -type f 2>/dev/null)" ] || lw_fail "messages in the chat queue"
[ ! -e /etc/lw-notify/queue ] || lw_fail "chat queue directory created"
[ ! -e /etc/lw-notify/reboot ] || lw_fail "restart note without a chat"
[ ! -e /etc/lw-notify/outage ] || lw_fail "outage record without a chat"
[ ! -e /tmp/lw-notify/offset ] || lw_fail "Bot API offset without a chat"
lw_expect_grep /etc/lw-notify/lastbal '^0.31|'
# the Telegram sides of the commands do nothing
: >"$T/at-calls"
lw-notify flush
lw-notify balance
lw-notify speedtest-run x
ACTION=ifup INTERFACE=wwan sh /etc/hotplug.d/iface/95-lw-notify
sleep 1
[ ! -e "$G/calls" ] || lw_fail "the Bot API was called by flush, balance or the hotplug"
lw_expect_eq "$(cat "$T/at-calls")" "" "AT commands of flush, balance, speedtest-run"
lw_expect_eq "$(sms_out)" 2 "SMS sent by flush, balance, speedtest-run"

# --- REBOOT: reply, then the restart, no note; the command is not run again after the start
sms_cmd "$ADMIN" REBOOT
lw_expect_eq "$(sms_body 3)" "Home router: restarting now, back in about 2 min." "REBOOT reply"
lw_expect_eq "$(grep '^reboot' "$T/events")" "reboot note=no" "restart without a note"
[ ! -e /etc/lw-notify/reboot ] || lw_fail "restart note without a chat"
reboot_sim 90
passes 5
lw_expect_eq "$(reboots_n)" 1 "restarts after the start"
lw_expect_eq "$(sms_out)" 3 "replies after the start"
[ ! -e "$G/calls" ] || lw_fail "the Bot API was called after the restart"

# --- the real loop, the real clock, the poll shortened to 2 s; a command is answered in seconds
export LW_NOTIFY_CLOCK=/proc/uptime LW_NOTIFY_POLL=2 LW_NOTIFY_LONGPOLL=1
rm -rf /tmp/lw-notify
lw-notify run </dev/null >/dev/null 2>&1 &
svc=$!
sleep 3
sms_in 200 +48000000001 '11/07/26 12:00:00' 'help'
i=0
until [ "$(sms_out)" -ge 4 ] || [ "$i" -ge 10 ]; do
    sleep 1
    i=$((i + 1))
done
lw_expect_eq "$(sms_out)" 4 "reply from the service loop"
lw_expect_eq "$(sms_body 4)" "$HELP" "text from the service loop"
[ "$i" -le 6 ] || lw_fail "the reply took $i s with a 2 s poll"
kill "$svc"
i=0
while kill -0 "$svc" 2>/dev/null && [ "$i" -lt 5 ]; do
    sleep 1
    i=$((i + 1))
done
! kill -0 "$svc" 2>/dev/null || lw_fail "service did not stop on TERM"
[ ! -e "$G/calls" ] || lw_fail "the Bot API was called by the service loop"
sleep 2
no_orphans

# --- a list entry no sender can match (6 or 7 digits, or "00" and 4): the service still starts and
# stays up, or procd would respawn it every 5 s for ever
for entry in +001234 123456 +1234567; do
    admins_set "$entry"
    init_start
    lw_expect_eq "$(head -n 1 "$T/procd")" open "procd instance for the entry $entry"
    rm -rf /tmp/lw-notify
    lw-notify run </dev/null >/dev/null 2>&1 &
    svc=$!
    sleep 2
    kill -0 "$svc" 2>/dev/null || lw_fail "the service exited at once with the entry $entry"
    kill "$svc"
    sleep 1
done
sleep 1
no_orphans
echo ok
