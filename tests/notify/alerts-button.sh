# R37d: /alerts shows the 2G message switch also as a button. A tap changes the switch and the text
# (and the button) of the same message; the data of a button names the state it asks for, so an old
# button cannot flip the switch back; taps from other chats do nothing; the text command still works
# and its answer has the button too. R37c: the flash is written only when the state changes.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup 7.50
passes 2

flash_state() {
    find /etc /root -type f -exec ls -li {} + | sort
    find /etc /root -type f -exec md5sum {} + | sort
}
ON="🔔 Automatic messages
New SMS: on · Low balance: on · Internet back: on · 2G backup: on"
OFF="🔔 Automatic messages
New SMS: on · Low balance: on · Internet back: on · 2G backup: off"

# the list comes with one button: turn the 2G message off
tg_push "$TG_CHAT" /alerts
pass
lw_expect_eq "$(last_text)" "$ON" "/alerts text"
lw_expect_eq "$(markup_of 1 | jsonfilter -e '@.inline_keyboard[*][*].text')" "2G backup: turn off" "button text"
lw_expect_eq "$(button_data 1 1)" al:2g:off "button data"
lw_expect_eq "$(markup_of 1 | jsonfilter -e '@.inline_keyboard[*][*]' | wc -l | tr -d ' ')" 1 "number of buttons"
# the callback_query kind was asked for, or Telegram would never send a tap
lw_expect_grep "$G/allowed" callback_query

# a tap from a member of the group: answered, and the same message shows the new state and button
tg_tap "$TG_CHAT" 1 al:2g:off Alice
before=$(flash_state)
pass
lw_expect_eq "$(sent)" 1 "messages after a tap (it edits, it does not send)"
lw_expect_eq "$(answers)" 1 "answers to the tap"
lw_expect_eq "$(answer_id 1)" "$TAP_ID" "the answer names the tap"
lw_expect_eq "$(answer_alert 1)" "" "pop-up for a normal tap"
lw_expect_eq "$(edits)" 1 "edits"
lw_expect_eq "$(edit_msgid 1)" 1 "edited message"
lw_expect_eq "$(edit_text 1)" "$OFF" "text after the tap"
lw_expect_eq "$(button_data 1 1)" al:2g:on "button after the tap"
lw_expect_eq "$(markup_of 1 | jsonfilter -e '@.inline_keyboard[*][*].text')" "2G backup: turn on" "button text after the tap"
[ -e /etc/lw-notify/no-2g ] || lw_fail "the tap did not switch the message off"
[ "$(flash_state)" != "$before" ] || lw_fail "the switch left no mark on flash"

# the same old button again: nothing changes, nothing is written, the tap is still answered
before=$(flash_state)
tg_tap "$TG_CHAT" 1 al:2g:off
pass
[ -e /etc/lw-notify/no-2g ] || lw_fail "an old button flipped the switch back"
lw_expect_eq "$(flash_state)" "$before" "flash after a tap that changes nothing"
lw_expect_eq "$(answers)" 2 "answers after the second tap"
lw_expect_eq "$(sent)" 1 "messages after the second tap"
# Telegram refuses an edit to the same text and buttons (400); that is no reason for the ASCII copy
lw_expect_eq "$(edits)" 1 "edits after a tap that changes nothing"
lw_expect_eq "$(shown 1)" "$OFF" "text after a tap that changes nothing"

# the new button turns it on; the file is gone
tg_tap "$TG_CHAT" 1 al:2g:on
pass
[ ! -e /etc/lw-notify/no-2g ] || lw_fail "the 'turn on' button left the switch off"
lw_expect_eq "$(edit_text "$(edits)")" "$ON" "text after turning on"
lw_expect_eq "$(button_data 1 1)" al:2g:off "button after turning on"

# a tap from another chat: no answer, no edit, no change
n=$(answers)
e=$(edits)
tg_tap "$TG_OTHER" 1 al:2g:off Mallory
pass
lw_expect_eq "$(answers)" "$n" "answers to a foreign tap"
lw_expect_eq "$(edits)" "$e" "edits after a foreign tap"
[ ! -e /etc/lw-notify/no-2g ] || lw_fail "a foreign chat switched the message off"

# an unknown button gets its spinner stopped and changes nothing
tg_tap "$TG_CHAT" 1 zz:unknown
pass
lw_expect_eq "$(answers)" $((n + 1)) "answer to an unknown button"
lw_expect_eq "$(edits)" "$e" "edits after an unknown button"

# the text command still works, and its answer carries the button for the new state
tg_push "$TG_CHAT" '/alerts 2g off'
pass
lw_expect_eq "$(last_text | head -n 1)" "🔔 2G backup message is now off." "text command confirmation"
lw_expect_eq "$(button_data "$(sent)" 1)" al:2g:on "button under the confirmation"
[ -e /etc/lw-notify/no-2g ] || lw_fail "the text command did not switch the message off"
# and a tap on the button of that answer turns it on again
tg_tap "$TG_CHAT" "$(sent)" "$(button_data "$(sent)" 1)"
pass
[ ! -e /etc/lw-notify/no-2g ] || lw_fail "the button under the confirmation did not turn it on"
lw_expect_eq "$(edit_text "$(edits)")" "$ON" "text after the second turning on"
no_orphans
echo ok
