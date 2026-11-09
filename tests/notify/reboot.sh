# R45, R45a, R37a, D60: /reboot asks with two buttons; the router restarts only on a tap of Restart,
# inside 60 s, from the configured chat, once; cancel, the 60 s end, a newer question, a service
# restart and a foreign chat never restart it; an old button gets the pop-up and does nothing. The
# restart leaves one note on flash (who, when), the first pass after the boot sends "Router back"
# once (with "~" when the clock was not synced at either end) and deletes it; a restart nobody
# asked for sends nothing; /status names the reason.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup 7.50
passes 2
nlbw_set "aa:bb:cc:00:00:01 1000000000 0"

QUESTION="⚠️ Restart the router?
Internet and Wi-Fi go down for about 2 min."
POPUP='This button expired, send /reboot again'
NOKB='{"inline_keyboard":[]}'

# ask: /reboot from the chat; Q is the id of the question message. The buttons are noted at once:
# the message loses them when the question ends, and a late tap still carries the old data.
ask() {
    tg_push "$TG_CHAT" /reboot
    pass
    Q=$(sent)
    button_data "$Q" 1 >"$T/go.$Q"
    button_data "$Q" 2 >"$T/no.$Q"
}
go() { cat "$T/go.$1"; }
no() { cat "$T/no.$1"; }
reboots() { grep -c '^reboot' "$T/events" || :; }
# lapse S: S seconds pass on both clocks, without a service pass
lapse() { lw_uptime_add "$1"; wall_add "$1"; }
files() { find /etc /root -type f | sort; }
note() { sed -n "s/^$1=//p" /etc/lw-notify/reboot; }
# polls_n: long polls the fake Bot API has seen; wait_polls N: until it has seen N (the service runs
# on its own, so this waits at most 30 s and then fails)
polls_n() { wc -l <"$G/polls" | tr -d ' '; }
wait_polls() {
    _i=0
    while [ "$(polls_n)" -lt "$1" ] && [ "$_i" -lt 30 ]; do
        sleep 1
        _i=$((_i + 1))
    done
    [ "$(polls_n)" -ge "$1" ] || lw_fail "the service made $(polls_n) polls, expected $1"
}

# --- the question: text, two buttons, one nonce, nothing restarted yet
ask
lw_expect_eq "$(last_text)" "$QUESTION" "the question"
lw_expect_eq "$(markup_of "$Q" | jsonfilter -e '@.inline_keyboard[0][*].text' | tr '\n' '|')" \
    "🔄 Restart|Cancel|" "button texts"
lw_expect_eq "$(markup_of "$Q" | jsonfilter -e '@.inline_keyboard[*]' | wc -l | tr -d ' ')" 1 "one row"
nonce=$(go "$Q" | sed -n 's/^rb:\([0-9a-f]*\):go$/\1/p')
lw_expect_eq "${#nonce}" 8 "nonce length"
lw_expect_eq "$(no "$Q")" "rb:$nonce:no" "Cancel data"
[ "${#nonce}" -gt 0 ] && [ "$(go "$Q" | wc -c)" -le 64 ] || lw_fail "callback data longer than 64 bytes"
lw_expect_grep "$G/allowed" callback_query
lw_expect_eq "$(reboots)" 0 "restarts before any tap"
passes 3
lw_expect_eq "$(reboots)" 0 "restarts while nobody taps"
lw_expect_eq "$(edits)" 0 "edits while the question is open"
# a command from another chat is not answered (R37)
n=$(sent)
tg_push "$TG_OTHER" /reboot
pass
lw_expect_eq "$(sent)" "$n" "answer to a foreign chat"
# another chat's tap on a valid button: no answer, no edit, no restart; the question stays open
tg_tap "$TG_OTHER" "$Q" "$(go "$Q")" Mallory
pass
lw_expect_eq "$(answers)" 0 "answers to a foreign tap"
lw_expect_eq "$(edits)" 0 "edits after a foreign tap"
lw_expect_eq "$(reboots)" 0 "restarts after a foreign tap"

# --- the R45 scenario: Alice taps Restart after 20 s
lapse 15
files >"$T/files.before"
tap_wall=$(($(cat "$T/wall") + 1))
GO=$(go "$Q")
tg_tap "$TG_CHAT" "$Q" "$GO" Alice
pass
lw_expect_eq "$(reboots)" 1 "restarts after the tap"
lw_expect_eq "$(grep '^reboot' "$T/events")" "reboot note=yes" "the note is on flash before the restart"
lw_expect_eq "$(answers)" 1 "answers to the tap"
lw_expect_eq "$(answer_id 1)" "$TAP_ID" "answered tap"
lw_expect_eq "$(answer_alert 1)" "" "pop-up for a good tap"
lw_expect_eq "$(edits)" 1 "edits"
lw_expect_eq "$(edit_msgid 1)" "$Q" "edited message"
lw_expect_eq "$(edit_text 1)" "🔄 Restarting now (Alice tapped Restart)." "text after the tap"
lw_expect_eq "$(edit_markup 1)" "$NOKB" "buttons after the tap"
lw_expect_eq "$(markup_of "$Q")" "$NOKB" "buttons left on the message"
lw_expect_eq "$(sent)" "$Q" "messages sent by the tap"
files >"$T/files.after"
lw_expect_eq "$(grep -vxFf "$T/files.before" "$T/files.after")" "/etc/lw-notify/reboot" \
    "files written by the restart"
lw_expect_eq "$(note name)" Alice "note: name"
lw_expect_eq "$(note wall)" "$tap_wall" "note: time"
lw_expect_eq "$(note ntp)" 1 "note: clock synced"
lw_expect_eq "$(note boot)" boot-0 "note: boot"
lw_expect_eq "$(wc -l <"$T/nlbw/commits" | tr -d ' ')" 1 "data counters committed before the restart"
# a second tap on the same button (a double tap): popup, no second restart
tg_tap "$TG_CHAT" "$Q" "$GO" Alice
pass
lw_expect_eq "$(reboots)" 1 "restarts after a double tap"
lw_expect_eq "$(answers)" 2 "answers after a double tap"
lw_expect_eq "$(answer_alert 2)" true "pop-up for the double tap"
lw_expect_eq "$(answer_text 2)" "$POPUP" "pop-up text"
lw_expect_eq "$(edits)" 1 "edits after a double tap"

# --- the restart itself: nothing at once, the clock is not set yet, then ntpd sets it
# the fake kernel changes its boot id; the service starts again with the clock unsynced
reboot_sim 30
ntp_off
wall_set '2026-11-07 11:20'
passes 2
lw_expect_eq "$(sent)" "$Q" "messages while the clock is not set"
ntp_on
echo $((tap_wall + 109)) >"$T/wall"
pass
lw_expect_eq "$(sent)" $((Q + 1)) "messages after the clock is set"
lw_expect_eq "$(last_text)" "🟢 Router back after restart (asked by Alice), down 1 min 50 s." "Router back"
[ ! -e /etc/lw-notify/reboot ] || lw_fail "the note is still on flash after the message"
tg_push "$TG_CHAT" /status
pass
case $(last_text) in
    *'(restarted from Telegram (Alice))'*) ;;
    *) lw_fail "/status after the restart: $(last_text)" ;;
esac
passes 3
lw_expect_eq "$(sent)" $((Q + 2)) "messages after the first one (no repeat)"
# an ordinary restart (power cut) afterwards: no message, and the reason is the usual one
reboot_sim 30
passes 3
lw_expect_eq "$(sent)" $((Q + 2)) "messages after a restart nobody asked for"
tg_push "$TG_CHAT" /status
pass
case $(last_text) in
    *'(power cut or manual restart)'*) ;;
    *) lw_fail "/status after a power cut: $(last_text)" ;;
esac

# --- Cancel
ask
lw_expect_eq "$(reboots)" 1 "restarts before the cancel"
tg_tap "$TG_CHAT" "$Q" "$(no "$Q")" Anna
pass
lw_expect_eq "$(edit_text "$(edits)")" "Restart cancelled." "text after Cancel"
lw_expect_eq "$(edit_markup "$(edits)")" "$NOKB" "buttons after Cancel"
lw_expect_eq "$(reboots)" 1 "restarts after Cancel"
lw_expect_eq "$(answer_alert "$(answers)")" "" "pop-up for Cancel"
[ ! -e /etc/lw-notify/reboot ] || lw_fail "a note on flash after Cancel"
# the Restart button of the cancelled question is dead
e=$(edits)
tg_tap "$TG_CHAT" "$Q" "$(go "$Q")" Anna
pass
lw_expect_eq "$(reboots)" 1 "restarts after a tap on a cancelled question"
lw_expect_eq "$(answer_text "$(answers)")" "$POPUP" "pop-up on a cancelled question"
lw_expect_eq "$(edits)" "$e" "edits after a tap on a cancelled question"

# --- 60 s without a tap: the message changes and loses its buttons, nothing restarts
ask
lapse 58
pass
lw_expect_eq "$(edits)" "$e" "edits at 59 s"
pass
lw_expect_eq "$(edits)" $((e + 1)) "edits at 60 s"
lw_expect_eq "$(edit_msgid "$(edits)")" "$Q" "message that ran out"
lw_expect_eq "$(edit_text "$(edits)")" "Restart not confirmed, nothing done." "text after 60 s"
lw_expect_eq "$(edit_markup "$(edits)")" "$NOKB" "buttons after 60 s"
passes 3
lw_expect_eq "$(edits)" $((e + 1)) "edits after the question ended"
tg_tap "$TG_CHAT" "$Q" "$(go "$Q")" Alice
pass
lw_expect_eq "$(reboots)" 1 "restarts after a tap at 61 s"
lw_expect_eq "$(answer_alert "$(answers)")" true "pop-up after 60 s"
lw_expect_eq "$(answer_text "$(answers)")" "$POPUP" "pop-up text after 60 s"
lw_expect_eq "$(edits)" $((e + 1)) "edits after the late tap"

# --- a tap that arrives after the question ran out but before the loop noticed (the loop only looks
# at the end of a question once per pass): the tap itself looks at the age. This calls the tap
# handler of the service code directly.
ask
Q1=$Q
e=$(edits)
(
    # shellcheck disable=SC1091  # the image's own files
    . /usr/lib/lw/common.sh && . /usr/lib/lw/notify.sh && . /usr/lib/lw/devices.sh &&
        . /usr/lib/lw/reboot.sh
    nt_config
    lw_uptime_add 61
    # shellcheck disable=SC2034  # read by nt_reboot_tap
    NT_CB=late NT_CBMSG=$Q1 NT_CBDATA=$(go "$Q1") NT_CBNAME=Alice
    nt_reboot_tap
)
lw_expect_eq "$(reboots)" 1 "restarts after a tap on a question that ran out"
lw_expect_eq "$(answer_alert "$(answers)")" true "pop-up for the late tap"
lw_expect_eq "$(answer_id "$(answers)")" late "the late tap is answered"
lw_expect_eq "$(edits)" "$e" "edits by the late tap itself"
pass
lw_expect_eq "$(edit_text "$(edits)")" "Restart not confirmed, nothing done." "the late question ends too"

# --- a newer question replaces the old one
ask
Q1=$Q
ask
Q2=$Q
lw_expect_eq "$(edit_msgid "$(edits)")" "$Q1" "old question edited by the new one"
lw_expect_eq "$(edit_text "$(edits)")" "Restart not confirmed, nothing done." "text of the old question"
[ "$(go "$Q1")" != "$(go "$Q2")" ] || lw_fail "two questions share a nonce"
tg_tap "$TG_CHAT" "$Q1" "$(go "$Q1")" Alice
pass
lw_expect_eq "$(reboots)" 1 "restarts after a tap on the replaced question"
lw_expect_eq "$(answer_text "$(answers)")" "$POPUP" "pop-up on the replaced question"
# the new one still works, and two taps in one pass restart once
tg_tap "$TG_CHAT" "$Q2" "$(go "$Q2")" Alice
tg_tap "$TG_CHAT" "$Q2" "$(go "$Q2")" Bob
pass
lw_expect_eq "$(reboots)" 2 "restarts after a double tap in one pass"
lw_expect_eq "$(note name)" Alice "who is named: the first tap"
lw_expect_eq "$(answer_alert "$(answers)")" true "pop-up for the second tap of the pair"
rm -f /etc/lw-notify/reboot

# --- the service restarts between the question and the tap: the old buttons are dead
ask
LW_NOTIFY_LONGPOLL=1 LW_NOTIFY_POLL=1 lw-notify run </dev/null >/dev/null 2>&1 &
svc=$!
sleep 2
kill "$svc"
wait "$svc" 2>/dev/null || :
lw_expect_eq "$(shown "$Q")" "Restart not confirmed, nothing done." "question left by a restarted service"
lw_expect_eq "$(markup_of "$Q")" "$NOKB" "buttons left by a restarted service"
tg_tap "$TG_CHAT" "$Q" "$(go "$Q")" Alice
pass
lw_expect_eq "$(reboots)" 2 "restarts after a tap on a question of the previous service"
lw_expect_eq "$(answer_text "$(answers)")" "$POPUP" "pop-up after the service restarted"

# --- the name: UTF-8, a JSON escape, an apostrophe, control characters, none, a long one
tapname() {
    ask
    tg_tap "$TG_CHAT" "$Q" "$(go "$Q")" "$1"
    pass
    lw_expect_eq "$(edit_text "$(edits)")" "🔄 Restarting now ($2 tapped Restart)." "text for the name $1"
    lw_expect_eq "$(note name)" "$2" "note for the name $1"
    rm -f /etc/lw-notify/reboot
}
tapname 'Zoë' 'Zoë'
tapname 'Mój' 'Mój'
tapname "O'Brien" "O'Brien"
tapname 'Al\u0007ic\u001be' 'Alice'
tapname '' someone
tapname 'abcdefghij1234567890abcdefghij1234567890EXTRA' 'abcdefghij1234567890abcdefghij1234567890'
lw_expect_eq "$(reboots)" 8 "restarts after the name tests"

# --- a clock that was not synced at the tap or at the end: the break is an estimate with "~"
# unsynced CLOCK_AT_TAP UPTIME CLOCK_AFTER: a restart asked with the clock on|off, then a boot that
# is UPTIME s old at the first pass, its clock on|off
unsynced() {
    rm -f /etc/lw-notify/reboot
    want=0
    if [ "$1" = on ]; then ntp_on && want=1; else ntp_off; fi
    ask
    tg_tap "$TG_CHAT" "$Q" "$(go "$Q")" Alice
    pass
    lw_expect_eq "$(note ntp)" "$want" "note: clock at the tap"
    reboot_sim "$(($2 - 1))"
    if [ "$3" = on ]; then ntp_on; else ntp_off; fi
}
n=$(sent)
unsynced off 126 off
pass
lw_expect_eq "$(sent)" $((n + 2)) "messages (question and Router back)"
lw_expect_eq "$(last_text)" "🟢 Router back after restart (asked by Alice), down ~2 min 46 s." "unsynced at both ends"
unsynced on 126 off
pass
lw_expect_eq "$(last_text)" "🟢 Router back after restart (asked by Alice), down ~2 min 46 s." "synced at the tap only"
unsynced off 61 on
pass
lw_expect_eq "$(last_text)" "🟢 Router back after restart (asked by Alice), down ~1 min 41 s." "synced at the end only"
# before 120 s of uptime and without a clock: it waits
unsynced on 31 off
passes 3
case $(last_text) in *'Router back'*) lw_fail "sent before the clock was set: $(last_text)" ;; esac
[ -e /etc/lw-notify/reboot ] || lw_fail "the note was removed before the message"
lw_uptime_set 119
pass
lw_expect_eq "$(last_text | head -n 1)" "🟢 Router back after restart (asked by Alice), down ~2 min 40 s." "after 120 s"

# --- Telegram is down at the first pass after the restart: the message waits and goes out once
rm -f /etc/lw-notify/reboot
ntp_on
ask
tg_tap "$TG_CHAT" "$Q" "$(go "$Q")" Alice
pass
reboot_sim 40
ntp_on
echo down >"$G/net"
passes 3
echo up >"$G/net"
n=$(sent)
passes 3
lw_expect_eq "$(sent)" $((n + 1)) "messages after Telegram is back"
case $(last_text) in *'Router back after restart (asked by Alice)'*) ;; *) lw_fail "late message" ;; esac
[ ! -e /etc/lw-notify/reboot ] || lw_fail "note kept after the late message"

# --- the restart did not happen (same boot): the note waits through the shutdown, then goes away
ask
tg_tap "$TG_CHAT" "$Q" "$(go "$Q")" Alice
pass
n=$(sent)
passes 3
lw_expect_eq "$(sent)" "$n" "messages during the shutdown"
[ -e /etc/lw-notify/reboot ] || lw_fail "the note went away while the router was shutting down"
lw_uptime_add 301
pass
[ ! -e /etc/lw-notify/reboot ] || lw_fail "a note of a restart that never came is still there"
reboot_sim 30
passes 3
lw_expect_eq "$(sent)" "$n" "messages after a later power cut"

# --- R37a: the restart is the only change the commands make besides the 2G switch
# shellcheck disable=SC2031  # T is set again by the sourced common.sh in the subshell above
lw_expect_eq "$(cat "$T/modem/zsnt")" 6,0,0 "modem mode"
lw_expect_eq "$(uci get network.wwan.modes)" lte "network.wwan.modes"
no_orphans
# --- the long poll does not sleep through the end of an open question: with a 30 s poll and an 8 s
# limit, the polls after the question are cut to what is left of the 8 s (the real clock here). The
# test waits for the service's state rather than sleeping: two polls mean the confirm call has set
# the offset (a /reboot sent before that would count as an old update), and the question file means
# the question is open.
: >"$G/polls"
LW_NOTIFY_CLOCK=/proc/uptime LW_NOTIFY_REBOOT_TTL=8 LW_NOTIFY_LONGPOLL=30 LW_NOTIFY_POLL=20 \
    lw-notify run </dev/null >/dev/null 2>&1 &
svc=$!
wait_polls 2
tg_push "$TG_CHAT" /reboot
_i=0
while [ ! -f /tmp/lw-notify/reboot_req ] && [ "$_i" -lt 30 ]; do
    sleep 1
    _i=$((_i + 1))
done
[ -f /tmp/lw-notify/reboot_req ] || lw_fail "no question after /reboot"
asked=$(polls_n)
wait_polls $((asked + 2))
kill "$svc"
wait "$svc" 2>/dev/null || :
rm -f /tmp/lw-notify/reboot_req
before=$(head -n "$asked" "$G/polls" | grep -v '^$' | tr '\n' ' ')
after=$(tail -n +"$((asked + 1))" "$G/polls" | grep -v '^$' | tr '\n' ' ')
# before the question the long poll waits for the inbox pass (NT_POLL, 20 s), never for the 30 s
# LONGPOLL, and at least one of those waits is longer than the 8 s limit, so the cut has work to do.
# The exact values move by a second with the clock (each stubbed poll takes about a second), so
# only the bounds are checked.
lw_expect_eq "$(head -n "$asked" "$G/polls" | awk '$1 > 20' | wc -l | tr -d ' ')" 0 \
    "poll longer than NT_POLL before the question: $before"
[ "$(head -n "$asked" "$G/polls" | awk '$1 > 8' | wc -l | tr -d ' ')" -ge 1 ] ||
    lw_fail "no poll longer than the limit before the question: $before"
# the polls of the question: the wait is cut to what is left of the 8 s, so none is longer than 8
lw_expect_eq "$(tail -n +"$((asked + 1))" "$G/polls" | awk '$1 > 8' | wc -l | tr -d ' ')" 0 \
    "polls cut to the end of the question: $after"
echo ok
