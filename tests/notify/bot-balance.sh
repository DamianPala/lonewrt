# R37 /balance: RACUN to 1466, the reply goes to the chat by the balance rule (R36: it answers a
# /balance from the last 10 min); no reply in 2 min gives one message about it, and a later reply
# within the 10 min still comes. A second /balance while waiting sends no second SMS.
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
expect_last 'Asked Telekom for the balance'
sms_in 0 1466 '11/07/26 10:00:20' 'Imate: 12.40 do 05.01.; '
passes 2
expect_sent 2
lw_expect_eq "$(last_text)" "✉️ Telekom 1466 · Today 10:00

Imate: 12.40 do 05.01.; 
= Balance 12.40 EUR, credit valid until 5 Jan" "balance reply above the threshold"

# no reply: one message after 120 s, none after that; the reply at 300 s still comes, with the note
tg_push "$TG_CHAT" '/balance@TestBot'
pass
expect_sent 3
lw_uptime_add 60
tg_push "$TG_CHAT" /balance
pass
expect_sent 4
expect_last "Still waiting for Telekom's answer"
lw_expect_eq "$(wc -l <"$T/sms-sent")" 2 "RACUN SMS sent"
lw_uptime_add 60
pass
expect_sent 5
expect_last 'No answer from Telekom yet'
passes 3
lw_uptime_add 100
pass
expect_sent 5
sms_in 1 1466 '11/07/26 10:05:00' 'Imate: 0.32 do 05.01.; '
passes 2
expect_sent 6
expect_last 'Imate: 0.32'
expect_last '⚠️ Low balance: 0.32 EUR (today 10:05)'
expect_last 'Top up at least 7.50 EUR'
# the low reading is remembered: the next weekly reply below the threshold stays quiet
lw-notify balance
sms_in 2 1466 '11/09/26 10:00:20' 'Imate: 0.30 do 05.01.; '
passes 2
expect_sent 6

# a reply after 10 min answers nothing: it is an ordinary SMS then (R36, D72)
tg_push "$TG_CHAT" /balance
pass
expect_sent 7
lw_uptime_add 130
pass
expect_sent 8
expect_last 'No answer from Telekom yet'
lw_uptime_add 500
pass
sms_in 3 1466 '11/09/26 11:00:20' 'Imate: 20.00 do 05.01.; '
passes 2
expect_sent 9
expect_last 'Imate: 20.00 do 05.01.;'
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
echo ok
