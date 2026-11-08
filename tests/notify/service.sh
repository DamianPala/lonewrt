# R38: one procd instance (/usr/sbin/lw-notify run, respawned without limit) only when token and
# chat are set. R38a: without them no instance, no API call, no AT command, no flash or syslog
# write; with only one of them one syslog entry at first boot. The service loop forwards a new SMS
# and answers a command within seconds and leaves nothing behind on TERM.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup ''

# procd stand-ins: record what the init script asks for
procd_open_instance() { echo open >>"$T/procd"; }
procd_set_param() { echo "$*" >>"$T/procd"; }
procd_close_instance() { echo close >>"$T/procd"; }
# start_service of the init script, as rc.common runs it, with these stand-ins
init_start() {
    : >"$T/procd"
    (
        # shellcheck source=src/files/etc/init.d/lw-notify
        . /etc/init.d/lw-notify
        start_service
    )
}

init_start
lw_expect_eq "$(cat "$T/procd")" "open
command /usr/sbin/lw-notify run
respawn 3600 5 0
close" "procd instance with token and chat"

# R38a: no token, no chat, or only one of them
for drop in token chat both; do
    notify_setup ''
    case $drop in
        token) uci -q delete lonewrt.notify.token ;;
        chat) uci -q delete lonewrt.notify.chat ;;
        both) uci -q delete lonewrt.notify.token && uci -q delete lonewrt.notify.chat ;;
    esac
    uci -q commit lonewrt
    rm -rf /etc/lw-notify /tmp/lw-notify "$G/calls"
    sms_in 0 +38200000001 '11/07/26 10:00:00' 'nobody reads this'
    tg_push "$TG_CHAT" /status
    init_start
    lw_expect_eq "$(cat "$T/procd")" "" "procd calls without $drop"
    for cmd in once flush balance; do lw-notify "$cmd"; done
    ACTION=ifup INTERFACE=wwan sh /etc/hotplug.d/iface/95-lw-notify
    sleep 1
    [ ! -e "$G/calls" ] || lw_fail "API called without $drop"
    lw_expect_eq "$(cat "$T/at-calls")" "" "AT commands without $drop"
    [ ! -e /etc/lw-notify ] && [ ! -e /tmp/lw-notify ] || lw_fail "state written without $drop"
    lw_expect_eq "$(cat "$T/syslog")" "" "syslog without $drop"
done
rc=0
lw-notify bogus 2>/dev/null || rc=$?
lw_expect_eq "$rc" 2 "exit code of an unknown subcommand"

# only one key at first boot: one entry, also when the service starts again
: >/etc/lw-notify.partial
init_start
init_start
off='lw-notify: notifications off: the profile sets only one of TG_BOT_TOKEN and TG_CHAT_ID'
lw_expect_eq "$(grep -c "$off" "$T/syslog")" 1 "partial-key entries"
[ ! -e /etc/lw-notify.partial ] || lw_fail "partial-key marker left"
lw_expect_eq "$(cat "$T/procd")" "" "procd calls with one key"

# the real loop, on the real clock, with the image's 15 s poll shortened to 2 s
notify_setup ''
export LW_NOTIFY_CLOCK=/proc/uptime LW_NOTIFY_POLL=2 LW_NOTIFY_LONGPOLL=1
lw-notify run </dev/null >/dev/null 2>&1 &
svc=$!
sleep 3
sms_in 1 +38200000001 '11/07/26 10:00:00' 'arrives while running'
i=0
until [ "$(sent)" -ge 1 ] || [ "$i" -ge 10 ]; do
    sleep 1
    i=$((i + 1))
done
expect_sent 1
expect_last 'arrives while running'
[ "$i" -le 6 ] || lw_fail "forwarding took $i s with a 2 s poll"
tg_push "$TG_CHAT" /help
i=0
until [ "$(sent)" -ge 2 ] || [ "$i" -ge 10 ]; do
    sleep 1
    i=$((i + 1))
done
expect_sent 2
[ "$i" -le 4 ] || lw_fail "the answer took $i s"
kill "$svc"
i=0
while kill -0 "$svc" 2>/dev/null && [ "$i" -lt 5 ]; do
    sleep 1
    i=$((i + 1))
done
! kill -0 "$svc" 2>/dev/null || lw_fail "service did not stop on TERM"
sleep 2

# R34d: the stderr of a call holds the URL with the token; a file left by a killed run goes at
# the start, and TERM in the middle of a call (Telegram not answering) leaves none behind
echo "$TG_TOKEN" >/tmp/lw-notify/err.1
lw-notify run </dev/null >/dev/null 2>&1 &
svc=$!
sleep 2
[ ! -e /tmp/lw-notify/err.1 ] || lw_fail "stderr file of a killed run kept at the start"
echo hang >"$G/net"
sleep 2
kill "$svc"
i=0
while kill -0 "$svc" 2>/dev/null && [ "$i" -lt 10 ]; do
    sleep 1
    i=$((i + 1))
done
! kill -0 "$svc" 2>/dev/null || lw_fail "service did not stop on TERM during a call"
! grep -rqF "$TG_TOKEN" /tmp/lw-notify || lw_fail "token left in /tmp/lw-notify after TERM"
sleep 2
no_orphans
echo ok
