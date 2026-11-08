# R35, R36: the weekly RACUN to 1466 (only with a threshold) and the balance rule. Scenario: with
# threshold 7.50 the weekly replies 8.00, 0.32, 0.32, 9.00, 0.50 put only the first 0.32 and the
# 0.50 on the chat, both with the low-balance warning; the memory survives a reboot.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup 7.50
passes 2

# weekly: RACUN sent, then the reply SMS comes in
i=0
for amount in 8.00 0.32 0.32 9.00 0.50; do
    : >"$T/sms-sent"
    lw-notify balance
    lw_expect_eq "$(cat "$T/sms-sent")" "1466 RACUN" "SMS sent by the weekly check"
    sms_in "$i" 1466 "11/0$((i + 1))/26 10:00:20" "Imate: $amount do 05.01.; "
    passes 2
    i=$((i + 1))
    # the reboot between weeks must not reset the memory
    [ "$i" != 3 ] || lw_reboot_sim
done
expect_sent 2
lw_expect_eq "$(sent_text 1)" "✉️ Telekom 1466 · 2 Nov 10:00

Imate: 0.32 do 05.01.; 
= Balance 0.32 EUR, credit valid until 5 Jan

⚠️ Low balance: 0.32 EUR (2 Nov 10:00)
Top up at least 7.50 EUR, or the data package will not renew." "first low-balance alert"
case $(sent_text 2) in
    *'Imate: 0.50 do'*'⚠️ Low balance: 0.50 EUR (5 Nov 10:00)
Top up at least 7.50 EUR'*) ;;
    *) lw_fail "second alert: $(sent_text 2)" ;;
esac
# the last known balance (amount, time of the reply) is on flash for /status (R39c)
lw_expect_eq "$(cat /etc/lw-notify/lastbal)" "0.50|2026-11-05 10:00" "last known balance"
lw_expect_grep "$T/syslog" "lw-notify: weekly balance check: RACUN sent to 1466"
lw_expect_eq "$(grep -c lw-notify "$T/syslog")" 5 "syslog entries (one per weekly check)"

# a comma amount and an equal amount: 7,50 is not below 7.50; 7.49 is
sms_in 5 1466 '11/06/26 10:00:20' 'Imate: 7,50 do 05.01.; '
passes 2
sms_in 6 1466 '11/07/26 10:00:20' 'Imate: 7.49 do 05.01.; '
passes 2
expect_sent 3
expect_last 'Imate: 7.49'

# other SMS from 1466 are forwarded as usual
sms_in 7 1466 '11/08/26 10:00:20' 'Usluga nije dostupna.'
passes 2
expect_sent 4
expect_last 'Usluga nije dostupna.'

# a failed send is logged; without a threshold there is no weekly RACUN at all (R36)
echo FAIL >"$T/at/SEND"
: >"$T/sms-sent"
lw-notify balance
lw_expect_grep "$T/syslog" "weekly balance check: sending RACUN to 1466 failed (exit 1)"
rm -f "$T/at/SEND"
uci -q delete lonewrt.notify.low_balance
uci -q commit lonewrt
: >"$T/syslog"
lw-notify balance
lw_expect_eq "$(cat "$T/sms-sent")" "" "SMS sent without a threshold"
lw_expect_eq "$(cat "$T/syslog")" "" "syslog without a threshold"
# without a threshold a balance reply that answers nothing stays off the chat
sms_in 8 1466 '11/09/26 10:00:20' 'Imate: 0.10 do 05.01.; '
passes 2
expect_sent 4
echo ok
