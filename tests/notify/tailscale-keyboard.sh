# R37e, R69c, D162: the keyboard of a tailscale image has 10 buttons in rows of 4, 3 and 3, and a press
# of `🔒 Tailscale` (with or without U+FE0F, with white space around) acts like /tailscale: the same
# answer, the link and its button while the router is not added, the state once it is. An image
# without Tailscale keeps the 3 x 3 keyboard (tests/notify/keyboard.sh) and the label is text without
# a slash there, ignored with no answer and no log line.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup ''
lw_net up down
echo HomeRouterBot >"$G/username"

FE=$(printf '\357\270\217')
LABEL='🔒 Tailscale'
ENVELOPE=$(printf '\342\234\211')
LABELS_TS='🟢 Status|📶 Wi-Fi|📱 Devices|⚡ Speed|💶 Balance|✉'"$FE"' SMS|🔔 Alerts|🔒 Tailscale|🔄 Reboot|❓ Help|'
LABELS_PLAIN='🟢 Status|📶 Wi-Fi|📱 Devices|⚡ Speed|💶 Balance|✉'"$FE"' SMS|🔔 Alerts|🔄 Reboot|❓ Help|'

# row_len KB ROW: the number of buttons in row ROW of the keyboard JSON
row_len() { printf '%s\n' "$1" | jsonfilter -e "@.keyboard[$2][*].text" | wc -l | tr -d ' '; }
labels() { printf '%s\n' "$1" | jsonfilter -e '@.keyboard[*][*].text' | tr '\n' '|'; }

# ---- a tailscale image: the greeting carries 10 buttons in rows of 4, 3 and 3
ts_on
ts_state added
kb_first_start
passes 2
expect_sent 2
KB=$(markup_of 2)
lw_expect_eq "$(labels "$KB")" "$LABELS_TS" "button labels in a tailscale image"
lw_expect_eq "$(printf '%s\n' "$KB" | jsonfilter -e '@.keyboard[*]' | wc -l | tr -d ' ')" 3 "rows"
lw_expect_eq "$(row_len "$KB" 0)" 4 "buttons in row 0"
lw_expect_eq "$(row_len "$KB" 1)" 3 "buttons in row 1"
lw_expect_eq "$(row_len "$KB" 2)" 3 "buttons in row 2"
lw_expect_eq "$(printf '%s\n' "$KB" | jsonfilter -e '@.keyboard[2][0].text')" "$LABEL" "first button of row 2"
lw_expect_eq "$(printf '%s\n' "$KB" | jsonfilter -e '@.is_persistent')" true "is_persistent"
lw_expect_eq "$(printf '%s\n' "$KB" | jsonfilter -e '@.resize_keyboard')" true "resize_keyboard"
case $KB in *"$ENVELOPE$FE SMS"*) ;; *) lw_fail "the envelope button lacks U+FE0F: $KB" ;; esac
# /help and /start carry the same keyboard
for c in /help /start; do
    tg_push "$TG_CHAT" "$c"
    pass
    lw_expect_eq "$(markup_of "$(sent)")" "$KB" "keyboard with $c"
done

# ---- a press acts like /tailscale: the state of an added router, in every spelling of the label
tg_push "$TG_CHAT" /tailscale
pass
STATE=$(last_text)
case $STATE in '🔒 <b>Tailscale: on as lte-router</b>'*) ;; *) lw_fail "/tailscale: $STATE" ;; esac
lw_expect_eq "$(markup_of "$(sent)")" '' "buttons of the state"
n=$(sent)
for text in "$LABEL" "  $LABEL  " "🔒$FE Tailscale" "  🔒$FE Tailscale "; do
    tg_push "$TG_CHAT" "$text"
    pass
    n=$((n + 1))
    expect_sent "$n"
    lw_expect_eq "$(last_text)" "$STATE" "answer to the press of '$text'"
    lw_expect_eq "$(markup_of "$n")" '' "buttons of the answer to '$text'"
done
# the lower-case label and text around it are not the button
c=$(sendcalls)
: >"$T/syslog"
for text in '🔒 tailscale' 'Tailscale' '🔒' '🔒 Tailscale please' 'please 🔒 Tailscale'; do
    tg_push "$TG_CHAT" "$text"
done
pass
expect_sent "$n"
lw_expect_eq "$(sendcalls)" "$c" "sendMessage calls for other text"
lw_expect_eq "$(cat "$T/syslog")" "" "syslog for other text"

# ---- the router is not added: the press gives a new link with its button, like /tailscale (R65a)
ts_state not_added
tg_push "$TG_CHAT" /tailscale
pass
LINK=$(last_text)
case $LINK in *'Add this router to Tailscale'*'https://login.tailscale.com/a/'*) ;; *) lw_fail "/tailscale: $LINK" ;; esac
lw_expect_eq "$(button_data "$(sent)" 1)" ts:link "button of /tailscale"
m=$(sent)
tg_push "$TG_CHAT" "$LABEL"
pass
lw_expect_eq "$(sent)" $((m + 1)) "answers to the press"
case $(last_text) in
    *'Add this router to Tailscale'*'https://login.tailscale.com/a/'*) ;;
    *) lw_fail "press, not added: $(last_text)" ;;
esac
lw_expect_eq "$(button_data "$(sent)" 1)" ts:link "button of the answer to the press"
lw_expect_eq "$(find /etc/lw-notify/queue -type f 2>/dev/null | wc -l | tr -d ' ')" 0 "queue after the press"
expect_all_html

# ---- an image without Tailscale: the 9 buttons of R37e, and the label is ignored
rm -f /usr/sbin/lw-tailscale
kb_first_start
passes 2
KB=$(markup_of "$(sent)")
lw_expect_eq "$(labels "$KB")" "$LABELS_PLAIN" "button labels in an image without Tailscale"
for r in 0 1 2; do
    lw_expect_eq "$(row_len "$KB" "$r")" 3 "buttons in row $r of the plain keyboard"
done
case $KB in *ailscale*) lw_fail "a Tailscale button in an image without it: $KB" ;; esac
n=$(sent)
c=$(sendcalls)
: >"$T/syslog"
for text in "$LABEL" "  🔒$FE Tailscale " /tailscale@HomeRouterBot; do
    tg_push "$TG_CHAT" "$text"
done
pass
# the typed command is no button: it gets the "not in this image" answer, the labels nothing
lw_expect_eq "$(sent)" $((n + 1)) "answers to the label and to /tailscale without Tailscale"
case $(last_text) in
    '🔒 Tailscale is not in this image.'*) ;;
    *) lw_fail "typed command: $(last_text)" ;;
esac
lw_expect_eq "$(cat "$T/syslog")" "" "syslog for the label without Tailscale"
no_orphans
echo ok
