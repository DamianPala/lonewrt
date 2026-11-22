# R65a, R72, R72a, R37, R37a, R65f, D152, D158: the link is taken when the message is sent, not when it
# fell due (a message queued without internet and a restart carries a link the service gave after it,
# and goes without one, naming /tailscale, when the service gives none); /tailscale and the button
# give a new link while the router is not added and its state once it is, never a link; starting, not
# running and an image without Tailscale; a command answer is not queued; a message Telegram refuses
# as HTML goes as plain text; and no link reaches syslog or the flash.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup ''
ts_on
ts_state not_added

NOLINK='Send /tailscale for a link.'

# --- no internet: the message waits in the queue as the name of the event, with no link, and the
# service is not asked for one (R72, R72a, R65f)
echo down >"$G/net"
ts_due link
passes 3
expect_sent 0
lw_expect_eq "$(ts_marked)" link "marked although it could not be sent"
lw_expect_eq "$(ts_link_calls)" 0 "link requests with no internet"
lw_expect_eq "$(cat /etc/lw-notify/queue/*-ts-link)" '@@TS:link@@' "queue file"
# a restart: the RAM goes, the queue stays; the message goes out once, with a link made after the restart
reboot_sim
echo up >"$G/net"
pass
expect_sent 1
lw_expect_eq "$(ts_links)" 1 "links made"
expect_last 'https://login.tailscale.com/a/LINK0001'
expect_last 'Not working? Send /tailscale for a new link.'
passes 2
expect_sent 1
lw_expect_eq "$(ts_marked)" link "marked once"

# --- the service gives no link when the message is sent: the message goes without one (R72a, D152),
# for each of the three messages; the link message keeps its button
for st in starting not_running; do
    ts_state "$st"
    n=$(sent)
    ts_due link
    pass
    lw_expect_eq "$(sent)" $((n + 1)) "messages, link message, $st"
    lw_expect_eq "$(last_text)" "🔗 <b>Add this router to Tailscale</b>
Sign in with the link to reach the router from your own devices. No account yet? Signing in makes a free one.
$NOLINK
Only for the person who manages this router: whoever signs in first gets access." "link message without a link, $st"
    lw_expect_eq "$(button_data "$(sent)" 1)" ts:link "button of the link message without a link, $st"
done
n=$(sent)
ts_down
ts_due refused expired
pass
lw_expect_eq "$(sent)" $((n + 2)) "messages with no service state"
lw_expect_eq "$(sent_text $((n + 1)))" "⚠️ <b>The Tailscale key in the profile did not work</b> (expired or already used).
Add the router with this link instead:
$NOLINK
Only for the person who manages this router: whoever signs in first gets access." "refusal without a link"
lw_expect_eq "$(last_text)" "🔴 <b>This router is no longer in Tailscale</b> (the sign-in ended, or it was removed)
Sign in again to get access back:
$NOLINK
Only for the person who manages this router: whoever signs in first gets access." "expired message without a link"
lw_expect_eq "$(ts_links)" 1 "links made while the service gave none"

# the router was added meanwhile (code 2): the same, no link
ts_state added
n=$(sent)
ts_due link
pass
lw_expect_eq "$(sent)" $((n + 1)) "messages, link message of an added router"
expect_last "$NOLINK"
lw_expect_eq "$(ts_links)" 1 "links made for an added router"

# a service that never answers ends at the bot's limit and the message goes without a link
ts_state ended
: >"$T/ts/hang"
n=$(sent)
ts_due expired
t0=$(date +%s)
pass
[ "$(elapsed_since "$t0")" -le 12 ] || lw_fail "a hung service held the pass for $(elapsed_since "$t0") s"
lw_expect_eq "$(sent)" $((n + 1)) "messages with a hung service"
expect_last "$NOLINK"
rm -f "$T/ts/hang"
sleep 1
no_orphans

# --- /tailscale, router not added: a link made now, every time a new one, with the button (R65a)
ts_state not_added
n=$(sent)
tg_push "$TG_CHAT" /tailscale
pass
lw_expect_eq "$(sent)" $((n + 1)) "answers to /tailscale"
lw_expect_eq "$(last_text)" '🔗 <b>Add this router to Tailscale</b>
Sign in with the link to reach the router from your own devices. No account yet? Signing in makes a free one.
https://login.tailscale.com/a/LINK0002
Only for the person who manages this router: whoever signs in first gets access.
Not working? Send /tailscale for a new link.' "answer to /tailscale"
lw_expect_eq "$(button_data "$(sent)" 1)" ts:link "button of the answer"
lw_expect_eq "$(preview_of "$(sent)")" '{"is_disabled":true}' "preview of the answer"
# the answer is no queue item, and the command asked for no event (R51)
lw_expect_eq "$(find /etc/lw-notify/queue -type f 2>/dev/null | wc -l | tr -d ' ')" 0 "queue after /tailscale"
tg_push "$TG_CHAT" '/Tailscale@TestBot'
pass
lw_expect_eq "$(sent)" $((n + 2)) "answers to /tailscale@TestBot"
expect_last 'https://login.tailscale.com/a/LINK0003'

# --- the button: the spinner stops, the answer is a new message with a new link (R65a)
m=$(sent)
tg_tap "$TG_CHAT" "$n" ts:link
pass
lw_expect_eq "$(answer_id 1)" "$TAP_ID" "callback answered"
lw_expect_eq "$(sent)" $((m + 1)) "messages after the tap"
expect_last 'https://login.tailscale.com/a/LINK0004'
lw_expect_eq "$(button_data "$(sent)" 1)" ts:link "button of the answer to the tap"
# a tap in another chat is ignored (R37)
tg_tap "$TG_OTHER" "$n" ts:link
pass
lw_expect_eq "$(sent)" $((m + 1)) "messages after a tap in another chat"
lw_expect_eq "$(ts_links)" 4 "links made"

# --- the router is added: /tailscale and the button give its state, never a link (R69b, D158)
ts_state added
m=$(sent)
tg_push "$TG_CHAT" /tailscale
pass
lw_expect_eq "$(sent)" $((m + 1)) "answers to /tailscale of an added router"
lw_expect_eq "$(last_text)" '🔒 <b>Tailscale: on as lte-router</b>
Address: 100.101.102.103
Account: jan@example.com
Sign-in ends: 21 May' "state of an added router"
lw_expect_eq "$(markup_of "$(sent)")" '' "buttons of the state"
tg_tap "$TG_CHAT" "$n" ts:link
pass
lw_expect_eq "$(sent)" $((m + 2)) "messages after the tap of an added router"
lw_expect_eq "$(last_text)" "$(sent_text $((m + 1)))" "state after the tap"
lw_expect_eq "$(ts_links)" 4 "links made for an added router"
# key expiry off: never; the route with TS_ADVERTISE_LAN, waiting and reachable (R69b)
ts_state added expiry_off=1 expiry=
ts_lan 1 192.168.5.0/24
for route in pending approved; do
    ts_state added expiry_off=1 expiry= "route=$route"
    tg_push "$TG_CHAT" /tailscale
    pass
    case $route in pending) want='waiting for approval' ;; *) want=reachable ;; esac
    lw_expect_eq "$(last_text)" "🔒 <b>Tailscale: on as lte-router</b>
Address: 100.101.102.103
Account: jan@example.com
Sign-in ends: never
Router's network 192.168.5.0/24: $want" "state with the route $route"
done
ts_lan 0

# --- starting and not running (R69d), also when the service has no state file or does not answer
for st in starting not_running; do
    ts_state "$st"
    tg_push "$TG_CHAT" /tailscale
    pass
    case $st in
        starting) want='⏳ Tailscale is starting, try again in a minute.' ;;
        *) want='⚠️ Tailscale is not running on the router.' ;;
    esac
    lw_expect_eq "$(last_text)" "$want" "answer, $st"
done
ts_down
tg_push "$TG_CHAT" /tailscale
pass
lw_expect_eq "$(last_text)" '⚠️ Tailscale is not running on the router.' "answer with no state file"
ts_state not_added
: >"$T/ts/hang"
tg_push "$TG_CHAT" /tailscale
t0=$(date +%s)
pass
[ "$(elapsed_since "$t0")" -le 12 ] || lw_fail "/tailscale with a hung service took $(elapsed_since "$t0") s"
lw_expect_eq "$(last_text)" '⏳ Tailscale is starting, try again in a minute.' "answer of a service that does not answer"
rm -f "$T/ts/hang"

# --- R37a: starting a sign-in changes nothing of the router's network or firewall
uci show network >"$T/net.before"
uci show firewall >"$T/fw.before" 2>/dev/null || :
ts_state not_added
tg_push "$TG_CHAT" /tailscale
pass
expect_last 'https://login.tailscale.com/a/LINK'
uci show network | cmp -s - "$T/net.before" || lw_fail "uci network changed"
{ uci show firewall 2>/dev/null || :; } | cmp -s - "$T/fw.before" || lw_fail "uci firewall changed"
lw_lines=$(cat "$T/sms-sent" 2>/dev/null || :)
lw_expect_eq "$lw_lines" "" "SMS sent by /tailscale"

expect_all_html

# --- a message Telegram refuses as HTML goes once as plain text, with the link, and is logged (R37g)
echo html >"$G/reject400"
ts_state not_added
n=$(sent)
ts_due link
: >"$T/syslog"
pass
lw_expect_eq "$(sent)" $((n + 1)) "messages with HTML refused"
lw_expect_eq "$(mode_of "$(sent)")" '' "parse_mode of the plain copy"
lw_expect_eq "$(sent_text "$(sent)" | head -n 1)" '🔗 Add this router to Tailscale' "plain copy"
expect_last 'https://login.tailscale.com/a/LINK'
lw_expect_eq "$(grep -c 'rejected a message as HTML' "$T/syslog")" 1 "log entries of the refused markup"
rm -f "$G/reject400"

# --- an image without Tailscale: /tailscale and the button say so, nothing is asked for (R37)
rm -f /usr/sbin/lw-tailscale
calls=$(ts_link_calls)
n=$(sent)
tg_push "$TG_CHAT" /tailscale
tg_tap "$TG_CHAT" "$n" ts:link
pass
lw_expect_eq "$(sent)" $((n + 2)) "answers without Tailscale"
lw_expect_eq "$(last_text)" '🔒 Tailscale is not in this image. Set TS_ENABLED to 1 in the profile and build again.' \
    "answer of an image without Tailscale"
lw_expect_eq "$(sent_text $((n + 1)))" "$(last_text)" "answer to the button without Tailscale"
lw_expect_eq "$(ts_link_calls)" "$calls" "link requests without Tailscale"
# what the service still says is due stays due: nobody takes it
ts_due link
passes 2
lw_expect_eq "$(sent)" $((n + 2)) "messages for an event of an image without Tailscale"

# --- R65f: no link in syslog or on flash
no_link_logged
lw_expect_no_grep "$T/syslog.prio" 'login.tailscale.com'
no_orphans
echo ok
