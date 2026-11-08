# R37e, D64: the persistent reply keyboard. It is a 3 x 3 Bot API keyboard (is_persistent,
# resize_keyboard) sent with the answer to /help and /start and once after the first start of the
# image (a flag on flash: not again after a restart of the service or of the router, again after a
# reset, retried while Telegram does not answer). A press arrives as a plain message with the label;
# the label (with or without U+FE0F, with white space around) runs its command; other text without
# a slash is ignored without an answer and without a log line; typed commands, also with the bot's
# name, keep working, and a command for another bot ("/help@OtherBot") is ignored.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup 7.50
lw_net up down
wifi_set 1
st_json 99 62 16 1
echo HomeRouterBot >"$G/username"

FE=$(printf '\357\270\217')
ENVELOPE=$(printf '\342\234\211')
LABELS='🟢 Status|📶 Wi-Fi|📱 Devices|⚡ Speed|💶 Balance|✉'"$FE"' SMS|🔔 Alerts|🔄 Reboot|❓ Help|'

# ---- first start: nothing sent before the first pass, then one message with the keyboard
kb_first_start
[ ! -e /etc/lw-notify/keyboard ] || lw_fail "flag present before the first start"
pass
expect_sent 1
KB=$(markup_of 1)
lw_expect_eq "$(printf '%s\n' "$KB" | jsonfilter -e '@.keyboard[*][*].text' | tr '\n' '|')" "$LABELS" \
    "button labels in order"
lw_expect_eq "$(printf '%s\n' "$KB" | jsonfilter -e '@.keyboard[*]' | wc -l | tr -d ' ')" 3 "rows"
for r in 0 1 2; do
    lw_expect_eq "$(printf '%s\n' "$KB" | jsonfilter -e "@.keyboard[$r][*].text" | wc -l | tr -d ' ')" 3 \
        "buttons in row $r"
done
lw_expect_eq "$(printf '%s\n' "$KB" | jsonfilter -e '@.is_persistent')" true "is_persistent"
lw_expect_eq "$(printf '%s\n' "$KB" | jsonfilter -e '@.resize_keyboard')" true "resize_keyboard"
case $KB in *"$ENVELOPE$FE SMS"*) ;; *) lw_fail "the envelope button lacks U+FE0F: $KB" ;; esac
[ -e /etc/lw-notify/keyboard ] || lw_fail "no flag after the first start"
lw_expect_eq "$(cat "$T/syslog")" "" "syslog after the first start"
passes 3
expect_sent 1

# ---- not again: after a restart of the router (RAM empty, flash kept) and of the service
reboot_sim 60
passes 2
expect_sent 1
LW_NOTIFY_CLOCK=/proc/uptime LW_NOTIFY_POLL=2 LW_NOTIFY_LONGPOLL=1 lw-notify run </dev/null \
    >/dev/null 2>&1 &
svc=$!
sleep 3
kill -TERM "$svc"
wait "$svc" || :
LW_NOTIFY_CLOCK=/proc/uptime LW_NOTIFY_POLL=2 LW_NOTIFY_LONGPOLL=1 lw-notify run </dev/null \
    >/dev/null 2>&1 &
svc=$!
sleep 3
kill -TERM "$svc"
wait "$svc" || :
expect_sent 1

# ---- again after a reset (it removes /etc/lw-notify); while Telegram is down it is retried, and
# written down only once it went out
rm -rf /etc/lw-notify /tmp/lw-notify
mkdir -p /tmp/lw-notify
echo down >"$G/net"
passes 3
[ ! -e /etc/lw-notify/keyboard ] || lw_fail "flag written though nothing was sent"
echo up >"$G/net"
pass
expect_sent 2
lw_expect_eq "$(markup_of 2)" "$KB" "keyboard after a reset"
[ -e /etc/lw-notify/keyboard ] || lw_fail "no flag after the second first start"
passes 3
expect_sent 2

# a flash that cannot be written: one send, not one per pass
rm -rf /etc/lw-notify /tmp/lw-notify
mkdir -p /tmp/lw-notify
mv_fail /lw-notify/keyboard
passes 3
expect_sent 3
mv_ok

# ---- Telegram rejects the message (HTTP 400, also as ASCII): dropped, one log line, no retry
rm -rf /etc/lw-notify /tmp/lw-notify
mkdir -p /tmp/lw-notify
echo all >"$G/reject400"
: >"$T/syslog"
passes 3
lw_expect_eq "$(rejected_n)" 2 "rejected tries"
expect_sent 3
[ -e /etc/lw-notify/keyboard ] || lw_fail "no flag after a rejected message"
lw_expect_eq "$(wc -l <"$T/syslog" | tr -d ' ')" 1 "syslog lines for a rejected keyboard message"
lw_expect_grep "$T/syslog" "lw-notify: Telegram rejected the keyboard message"
rm -f "$G/reject400"

# ---- /help and /start carry the keyboard, also with the bot's name; an unknown command does not
n=$(sent)
for c in /help /start '/HELP@HomeRouterBot' '/start@HomeRouterBot'; do
    tg_push "$TG_CHAT" "$c"
    pass
    n=$((n + 1))
    expect_sent "$n"
    expect_last '/status – is the internet OK'
    lw_expect_eq "$(markup_of "$n")" "$KB" "keyboard with $c"
done
tg_push "$TG_CHAT" /restart
pass
n=$((n + 1))
expect_sent "$n"
expect_last '/status – is the internet OK'
lw_expect_eq "$(markup_of "$n")" "" "keyboard with an unknown command"

# ---- every button, as the client may send it: exact, with U+FE0F toggled, with white space around
cat >"$T/buttons" <<'BTNEOF'
🟢 Status|Tech:
📶 Wi-Fi|📶
📱 Devices|📱 Devices
⚡ Speed|Speed test
💶 Balance|Telekom
✉️ SMS|📥
🔔 Alerts|🔔 Automatic messages
🔄 Reboot|Restart the router?
❓ Help|/status – is the internet OK
BTNEOF
: >"$T/variants"
while IFS='|' read -r label want; do
    emoji=${label%% *}
    word=${label#* }
    case $emoji in
        *"$FE"*) toggled="${emoji%"$FE"} $word" ;;
        *) toggled="$emoji$FE $word" ;;
    esac
    {
        printf '%s|%s|%s\n' "$label" "$want" exact
        printf '%s|%s|%s\n' "$toggled" "$want" toggled
        printf '%s|%s|%s\n' "  $label  " "$want" padded
        printf '%s|%s|%s\n' "  $toggled " "$want" "padded and toggled"
    } >>"$T/variants"
done <"$T/buttons"
# a press as the real group delivers it: in reply to the bot's keyboard message (measured 2026-11-08)
push_reply() {
    _id=$(cat "$G/next_id")
    echo $((_id + 1)) >"$G/next_id"
    {
        printf '{"update_id":%s,"message":{"message_id":%s,' "$_id" "$_id"
        printf '"from":{"id":42,"first_name":"Alice"},'
        printf '"chat":{"id":%s,"type":"supergroup"},"date":1790000000,' "$TG_CHAT"
        printf '"reply_to_message":{"message_id":1,"from":{"id":7,"is_bot":true},'
        printf '"chat":{"id":%s},"text":"The router bot is ready."},"text":"%s"}}' "$TG_CHAT" "$1"
    } >"$G/updates/$_id.json"
}
presses=0
while IFS='|' read -r text want how; do
    n=$(sent)
    if [ $((presses % 2)) = 0 ]; then tg_push "$TG_CHAT" "$text"; else push_reply "$text"; fi
    pass </dev/null
    case $text in *Speed*) st_wait; pass </dev/null ;; esac
    [ "$(sent)" -gt "$n" ] || lw_fail "no answer to the button '$text' ($how)"
    case $(sent_text $((n + 1))) in
        *"$want"*) ;;
        *) lw_fail "button '$text' ($how) did not run its command: $(sent_text $((n + 1)))" ;;
    esac
    presses=$((presses + 1))
done <"$T/variants"
lw_expect_eq "$presses" 36 "button presses"

# ---- other text is ignored: no answer, no log line, no API call but the poll
n=$(sent)
c=$(sendcalls)
: >"$T/syslog"
i=0
while IFS= read -r text; do
    tg_push "$TG_CHAT" "$text"
    i=$((i + 1))
done <<'TXTEOF'
hello router
Status
status
Help
wifi
🟢
🟢 Statu
🟢 status
❓ HELP
🟢 Status please
please 🟢 Status
🟢 Status 🟢 Status
🟢 Status\nplease
📶📶 Wi-Fi
Wi-Fi 📶
✉ SMS!
TXTEOF
tg_push "$TG_CHAT" "$(printf 'x%.0s' $(seq 1 200))"
i=$((i + 1))
# the label of a button in the chat of someone else
tg_push "$TG_OTHER" '🟢 Status'
tg_push "$TG_OTHER" '❓ Help'
pass
lw_expect_eq "$(sent)" "$n" "answers to other text"
lw_expect_eq "$(sendcalls)" "$c" "sendMessage calls for other text"
lw_expect_eq "$(cat "$T/syslog")" "" "syslog for other text"
[ "$i" -ge 15 ] || lw_fail "test setup: $i texts"

# ---- privacy mode is off (D64): a command for another bot of the group is not ours
n=$(sent)
c=$(sendcalls)
: >"$T/syslog"
for t in '/help@OtherBot' '/STATUS@otherbot' '/help@HomeRouterBot2' '/start@' \
    '/reboot@x_bot now'; do
    tg_push "$TG_CHAT" "$t"
done
pass
lw_expect_eq "$(sent)" "$n" "answers to commands for another bot"
lw_expect_eq "$(sendcalls)" "$c" "sendMessage calls for commands for another bot"
lw_expect_eq "$(cat "$T/syslog")" "" "syslog for commands for another bot"

# ---- the keyboard does not break typed commands; the bot's name in any case, getMe once a run
tg_push "$TG_CHAT" '/Status@HomeRouterBot'
pass
expect_last 'Tech:'
tg_push "$TG_CHAT" '/help@homerouterbot'
pass
expect_last '/status – is the internet OK'
lw_expect_eq "$(grep -c '^getMe$' "$G/calls")" 1 "getMe calls"
no_orphans
echo ok
