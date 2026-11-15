# R37e, D64: the persistent reply keyboard. It is a 3 x 3 Bot API keyboard (is_persistent,
# resize_keyboard) sent with the answer to /help and /start and once after the first start of the
# image (a flag on flash: not again after a restart of the service or of the router, again after a
# reset, retried while Telegram does not answer). A press arrives as a plain message with the label;
# the label (with or without U+FE0F, with white space around) runs its command; other text without
# a slash is ignored without an answer and without a log line; typed commands, also with the bot's
# name, keep working, and a command for another bot ("/help@OtherBot") is ignored.
# R37f, D75, D84: before the greeting the chat gets a message of its own with two lines that say the
# router was reset, but only when the state on flash was empty at the start (no flag, nothing else in
# /etc/lw-notify). It is apart from the greeting because a press of a button is a reply to the
# message that carries the keyboard, and every press would quote "Router was reset".
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
HELLO='🤖 The router bot is ready. Tap a button below, or send /help to see what each one does.'
RESET='🔄 <b>Router was reset to its built-in settings.</b>
Earlier logs and saved SMS are gone.'
LABELS='🟢 Status|📶 Wi-Fi|📱 Devices|⚡ Speed|💶 Balance|✉'"$FE"' SMS|🔔 Alerts|🔄 Reboot|❓ Help|'

# ---- first start: nothing sent before the first pass, then the reset note and, as the second
# message, the greeting with the keyboard (the note has none)
kb_first_start
[ ! -e /etc/lw-notify/keyboard ] || lw_fail "flag present before the first start"
pass
expect_sent 2
lw_expect_eq "$(markup_of 1)" "" "keyboard on the reset note"
KB=$(markup_of 2)
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
lw_expect_eq "$(sent_text 1)" "$RESET" "reset note of the first start"
lw_expect_eq "$(sent_text 2)" "$HELLO" "greeting of the first start"
[ ! -e /etc/lw-notify/reset-note ] || lw_fail "reset note left after the greeting went out"
lw_expect_eq "$(cat "$T/syslog")" "" "syslog after the first start"
expect_all_html
passes 3
expect_sent 2

# ---- not again: after a restart of the router (RAM empty, flash kept) and of the service
reboot_sim 60
passes 2
expect_sent 2
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
expect_sent 2

# ---- again after a reset (it removes /etc/lw-notify); while Telegram is down it is retried, and
# written down only once it went out
rm -rf /etc/lw-notify /tmp/lw-notify
mkdir -p /tmp/lw-notify
echo down >"$G/net"
passes 3
[ ! -e /etc/lw-notify/keyboard ] || lw_fail "flag written though nothing was sent"
echo up >"$G/net"
pass
expect_sent 4
lw_expect_eq "$(markup_of 4)" "$KB" "keyboard after a reset"
lw_expect_eq "$(markup_of 3)" "" "no keyboard on the reset note after a reset"
lw_expect_eq "$(sent_text 3)" "$RESET" "reset note after a reset"
lw_expect_eq "$(sent_text 4)" "$HELLO" "greeting after a reset"
[ -e /etc/lw-notify/keyboard ] || lw_fail "no flag after the second first start"
passes 3
expect_sent 4

# a flash that cannot be written: one send, not one per pass
rm -rf /etc/lw-notify /tmp/lw-notify
mkdir -p /tmp/lw-notify
mv_fail /lw-notify/keyboard
passes 3
expect_sent 6
mv_ok

# ---- Telegram rejects the messages (HTTP 400, also as plain text and ASCII): each dropped with one
# log line, no retry
rm -rf /etc/lw-notify /tmp/lw-notify
mkdir -p /tmp/lw-notify
echo all >"$G/reject400"
: >"$T/syslog"
passes 3
lw_expect_eq "$(rejected_n)" 6 "rejected tries (HTML, plain, ASCII for each of the two messages)"
expect_sent 6
[ -e /etc/lw-notify/keyboard ] || lw_fail "no flag after a rejected message"
lw_expect_eq "$(wc -l <"$T/syslog" | tr -d ' ')" 2 "syslog lines for the rejected messages"
lw_expect_grep "$T/syslog" "lw-notify: Telegram rejected the reset note"
lw_expect_grep "$T/syslog" "lw-notify: Telegram rejected the keyboard message"
rm -f "$G/reject400"

# ---- a reset while Telegram is down and a router restart before the greeting went out: the reset
# lines are not lost, though other state (the SMS keys) is on flash by then
n=$(sent)
rm -rf /etc/lw-notify /tmp/lw-notify
mkdir -p /tmp/lw-notify
echo down >"$G/net"
passes 3
[ -e /etc/lw-notify/seen ] || lw_fail "the first scan wrote no SMS keys: the case is not tested"
reboot_sim 60
passes 2
expect_sent "$n"
echo up >"$G/net"
pass
expect_sent $((n + 2))
lw_expect_eq "$(sent_text $((n + 1)))" "$RESET" "reset note after a reset and a restart before it went out"
lw_expect_eq "$(sent_text $((n + 2)))" "$HELLO" "greeting after a reset and a restart before it went out"
passes 2
expect_sent $((n + 2))

# ---- the note went out, the greeting did not (Telegram dropped, the router restarted): the state
# says so ("sent"), so only the greeting comes, and the note is not repeated
n=$(sent)
rm -rf /etc/lw-notify /tmp/lw-notify
mkdir -p /etc/lw-notify /tmp/lw-notify
echo sent >/etc/lw-notify/reset-note
pass
expect_sent $((n + 1))
lw_expect_eq "$(sent_text $((n + 1)))" "$HELLO" "greeting alone after the note went out"
[ ! -e /etc/lw-notify/reset-note ] || lw_fail "reset note left after the greeting"

# ---- not a reset: an image flashed with its state kept (sysupgrade -o) has state on flash but no
# flag (an earlier image had no keyboard): the greeting alone, without the reset lines
n=$(sent)
rm -rf /etc/lw-notify /tmp/lw-notify
mkdir -p /etc/lw-notify /tmp/lw-notify
: >/etc/lw-notify/seen
pass
expect_sent $((n + 1))
lw_expect_eq "$(sent_text $((n + 1)))" "$HELLO" "greeting on an image that kept its state"
[ -e /etc/lw-notify/keyboard ] || lw_fail "no flag on an image that kept its state"
[ ! -e /etc/lw-notify/reset-note ] || lw_fail "reset note on an image that kept its state"
passes 2
expect_sent $((n + 1))

# ---- /help and /start carry the keyboard, also with the bot's name; an unknown command does not
n=$(sent)
for c in /help /start '/HELP@HomeRouterBot' '/start@HomeRouterBot'; do
    tg_push "$TG_CHAT" "$c"
    pass
    n=$((n + 1))
    expect_sent "$n"
    expect_last '🟢 <b>Status</b> – is the internet OK'
    lw_expect_eq "$(markup_of "$n")" "$KB" "keyboard with $c"
done
tg_push "$TG_CHAT" /restart
pass
n=$((n + 1))
expect_sent "$n"
expect_last '🟢 <b>Status</b> – is the internet OK'
lw_expect_eq "$(markup_of "$n")" "" "keyboard with an unknown command"

# ---- every button, as the client may send it: exact, with U+FE0F toggled, with white space around
cat >"$T/buttons" <<'BTNEOF'
🟢 Status|Tech:
📶 Wi-Fi|📶
📱 Devices|Devices</b>
⚡ Speed|Speed test
💶 Balance|Telekom
✉️ SMS|📥
🔔 Alerts|Automatic messages
🔄 Reboot|Restart the router?
❓ Help|🟢 <b>Status</b> – is the internet OK
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
expect_last '🟢 <b>Status</b> – is the internet OK'
lw_expect_eq "$(grep -c '^getMe$' "$G/calls")" 1 "getMe calls"
no_orphans
echo ok
