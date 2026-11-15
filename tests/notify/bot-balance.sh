# R37 /balance: RACUN to 1466, the reply goes to the chat by the balance rule (R36: it answers a
# /balance from the last 10 min) and takes the place of the acknowledgement of the command, which is
# edited into the answer; no reply in 2 min gives one message about it, and a later reply within the
# 10 min still comes, as a new message (the edit above the notice would make no sound). A second
# /balance while waiting sends no second SMS.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup 7.50
passes 2

tg_push "$TG_CHAT" /balance
pass
lw_expect_eq "$(cat "$T/sms-sent")" "1466 RACUN" "SMS sent for /balance"
expect_sent 1
lw_expect_eq "$(last_text)" "💶 Asked Telekom for the balance (SMS to 1466). The answer comes here, usually within a minute." \
    "acknowledgement on one line"
sms_in 0 1466 '11/07/26 10:00:20' 'Imate: 12.40 do 05.01.; '
passes 2
expect_sent 1
lw_expect_eq "$(edits)" 1 "edits for the answer"
lw_expect_eq "$(edit_msgid 1)" 1 "edited message"
lw_expect_eq "$(shown 1)" "💶 <b>Balance: 12.40 EUR</b>, valid until 5 Jan
<blockquote>Telekom 1466, today 10:00:
Imate: 12.40 do 05.01.; </blockquote>" "balance reply above the threshold, in place of the acknowledgement"

# no reply: one message after 120 s, none after that; the reply at 300 s still comes, with the note,
# as a message of its own (R37)
tg_push "$TG_CHAT" '/balance@TestBot'
pass
expect_sent 2
lw_uptime_add 60
tg_push "$TG_CHAT" /balance
pass
expect_sent 3
expect_last "Still waiting for Telekom's answer"
lw_expect_eq "$(wc -l <"$T/sms-sent")" 2 "RACUN SMS sent"
lw_uptime_add 60
pass
expect_sent 4
expect_last 'No answer from Telekom yet'
passes 3
lw_uptime_add 100
pass
expect_sent 4
sms_in 1 1466 '11/07/26 10:05:00' 'Imate: 0.32 do 05.01.; '
passes 2
expect_sent 5
lw_expect_eq "$(edits)" 1 "edits for an answer after the notice (a new message)"
expect_last 'Imate: 0.32'
expect_last '<b>Balance: 0.32 EUR</b>, valid until 5 Jan'
expect_last '⚠️ Top up at least 7.50 EUR, or the data package will not renew.'
expect_last 'Telekom 1466, today 10:05:'
# the low reading is remembered: the next weekly reply below the threshold stays quiet
lw-notify balance
sms_in 2 1466 '11/09/26 10:00:20' 'Imate: 0.30 do 05.01.; '
passes 2
expect_sent 5

# a reply after 10 min answers nothing: it is an ordinary SMS then (R36, D72)
tg_push "$TG_CHAT" /balance
pass
expect_sent 6
lw_uptime_add 130
pass
expect_sent 7
expect_last 'No answer from Telekom yet'
lw_uptime_add 500
pass
sms_in 3 1466 '11/09/26 11:00:20' 'Imate: 20.00 do 05.01.; '
passes 2
expect_sent 8
expect_last 'Imate: 20.00 do 05.01.;'
lw_expect_eq "$(edits)" 1 "edits for a reply after the window (a new message)"
case $(last_text) in *'= Balance'*) lw_fail "late reply with a translation: $(last_text)" ;; esac

# a modem that does not take the SMS
echo HANG >"$T/at/SEND"
tg_push "$TG_CHAT" /balance
t0=$(date +%s)
pass
[ "$(elapsed_since "$t0")" -le 6 ] || lw_fail "/balance with a hung modem took too long"
expect_last 'Could not ask Telekom for the balance'
rm -f "$T/at/SEND"
sleep 1
no_orphans
expect_all_html
echo ok
