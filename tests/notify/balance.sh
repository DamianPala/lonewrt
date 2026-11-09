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
lw-notify balance
sms_in 5 1466 '11/06/26 10:00:20' 'Imate: 7,50 do 05.01.; '
passes 2
lw-notify balance
sms_in 6 1466 '11/07/26 10:00:20' 'Imate: 7.49 do 05.01.; '
passes 2
expect_sent 3
expect_last 'Imate: 7.49'

# other SMS from 1466 are forwarded as usual
sms_in 7 1466 '11/08/26 10:00:20' 'Usluga nije dostupna.'
passes 2
expect_sent 4
expect_last 'Usluga nije dostupna.'

# R36 (D72): a message that fits the pattern is a balance only when the router asked within the last
# 10 min. Any other one is forwarded like an ordinary SMS, without the translation line and the
# warning, and the stored balance and the below-threshold memory stay as they were. The query is
# not used up by its answer: it only ages out with the window (see the race below).
bal_state() { cat /etc/lw-notify/lastbal /etc/lw-notify/balance 2>&1; }
before=$(bal_state)
lw_expect_eq "$before" "7.49|2026-11-07 10:00
1" "state before the unrequested messages"
n=$(sent)
# the last weekly query is older than the window by now
lw_uptime_add 601
# high, and low: no query, so both go to the chat as they are and change nothing
sms_in 8 1466 '11/08/26 11:00:00' 'Imate: 99.00 do 01.02.;'
passes 2
lw_expect_eq "$(sent)" $((n + 1)) "messages for an unrequested high amount"
lw_expect_eq "$(last_text)" "✉️ Telekom 1466 · 8 Nov 11:00

Imate: 99.00 do 01.02.;" "unrequested high amount: plain, no translation"
lw_expect_eq "$(bal_state)" "$before" "state after an unrequested high amount"
rm -f /etc/lw-notify/balance
sms_in 9 1466 '11/08/26 11:05:00' 'Imate: 0.10 do 01.02.;'
passes 2
lw_expect_eq "$(sent)" $((n + 2)) "messages for an unrequested low amount"
case $(last_text) in *'= Balance'* | *'Low balance'*) lw_fail "unrequested low amount: $(last_text)" ;; esac
[ ! -e /etc/lw-notify/balance ] || lw_fail "an unrequested low amount wrote the memory"
lw_expect_eq "$(cat /etc/lw-notify/lastbal)" "7.49|2026-11-07 10:00" "stored balance after an unrequested low amount"
printf '1\n' >/etc/lw-notify/balance
# the router asked: the answer counts, and so does every further one inside the window (D72)
lw-notify balance
sms_in 10 1466 '11/08/26 11:10:00' 'Imate: 12.00 do 01.02.;'
passes 2
lw_expect_eq "$(sent)" $((n + 2)) "messages for an asked, high amount (silent, R36)"
lw_expect_eq "$(cat /etc/lw-notify/lastbal)" "12.00|2026-11-08 11:10" "stored balance after an asked answer"
sms_in 11 1466 '11/08/26 11:11:00' 'Imate: 0.20 do 01.02.;'
passes 2
lw_expect_eq "$(sent)" $((n + 3)) "messages for a second answer to one query (new low)"
case $(last_text) in
    *'= Balance 0.20 EUR'*'⚠️ Low balance: 0.20 EUR'*) ;;
    *) lw_fail "second answer inside the window runs the rule: $(last_text)" ;;
esac
lw_expect_eq "$(cat /etc/lw-notify/lastbal)" "0.20|2026-11-08 11:11" "stored balance after the second answer"
# a query that is older than the window does not make an answer a balance
lw-notify balance
lw_uptime_add 601
sms_in 12 1466 '11/08/26 11:30:00' 'Imate: 0.30 do 01.02.;'
passes 2
lw_expect_eq "$(sent)" $((n + 4)) "messages for an answer after the window"
case $(last_text) in *'= Balance'* | *'Low balance'*) lw_fail "late answer: $(last_text)" ;; esac
lw_expect_eq "$(cat /etc/lw-notify/lastbal)" "0.20|2026-11-08 11:11" "stored balance after a late answer"
# /status shows the balance that was read in the window, not the one that came after it
tg_push "$TG_CHAT" /status
pass
case $(last_text) in *'Balance: 0.20 EUR'*) ;; *) lw_fail "status: $(last_text)" ;; esac
# only the first scan after a flash or a reset takes a balance without a query: one that came in
# during a restart is an ordinary SMS at the first scan after it
sms_in 14 1466 '11/08/26 11:40:00' 'Imate: 98.00 do 01.02.;'
lw_reboot_sim
n=$(sent)
passes 3
lw_expect_eq "$(sent)" $((n + 1)) "messages for an unrequested amount that came during a restart"
lw_expect_eq "$(cat /etc/lw-notify/lastbal)" "0.20|2026-11-08 11:11" "stored balance after a restart"

# R36 (D72), the race: a forged high reply between the weekly query and the real low one must not take
# the real one's place. Both count inside the window, the real low reply warns, and it is the one
# /status keeps because it is newer.
printf '0\n' >/etc/lw-notify/balance
lw-notify balance
n=$(sent)
sms_in 15 1466 '11/09/26 10:00:05' 'Imate: 99.00 do 01.02.;'
passes 2
lw_expect_eq "$(sent)" "$n" "messages for a forged high reply inside the window (silent)"
sms_in 16 1466 '11/09/26 10:00:20' 'Imate: 0.31 do 05.01.;'
passes 2
lw_expect_eq "$(sent)" $((n + 1)) "messages for the real low reply after a forged one"
case $(last_text) in
    *'= Balance 0.31 EUR'*'⚠️ Low balance: 0.31 EUR'*) ;;
    *) lw_fail "low-balance warning after a forged reply: $(last_text)" ;;
esac
lw_expect_eq "$(cat /etc/lw-notify/lastbal)" "0.31|2026-11-09 10:00" "stored balance after the race"
lw_expect_eq "$(cat /etc/lw-notify/balance)" 1 "below-threshold memory after the race"
# the reverse order is the accepted leftover: the warning has gone out, and a forged high reply that
# follows inside the window is what /status shows until the next real one
printf '0\n' >/etc/lw-notify/balance
lw-notify balance
n=$(sent)
sms_in 17 1466 '11/10/26 10:00:05' 'Imate: 0.40 do 05.01.;'
passes 2
lw_expect_eq "$(sent)" $((n + 1)) "messages for the real low reply"
case $(last_text) in *'⚠️ Low balance: 0.40 EUR'*) ;; *) lw_fail "warning: $(last_text)" ;; esac
sms_in 18 1466 '11/10/26 10:00:20' 'Imate: 99.00 do 01.02.;'
passes 2
lw_expect_eq "$(sent)" $((n + 1)) "messages for a forged high reply after the real one (silent)"
lw_expect_eq "$(cat /etc/lw-notify/lastbal)" "99.00|2026-11-10 10:00" "stored balance: the forged one (accepted leftover)"
# /balance from the chat with two replies inside the window: the first is the answer to the
# command, the second is checked by the rule only (silent unless it crosses the threshold)
printf '0\n' >/etc/lw-notify/balance
tg_push "$TG_CHAT" /balance
pass
n=$(sent)
sms_in 19 1466 '11/11/26 10:00:05' 'Imate: 12.40 do 05.01.;'
passes 2
lw_expect_eq "$(sent)" $((n + 1)) "messages for the first reply to /balance"
expect_last '= Balance 12.40 EUR'
sms_in 20 1466 '11/11/26 10:00:20' 'Imate: 12.50 do 05.01.;'
passes 2
lw_expect_eq "$(sent)" $((n + 1)) "messages for a second reply to /balance (silent)"
lw_expect_eq "$(cat /etc/lw-notify/lastbal)" "12.50|2026-11-11 10:00" "stored balance after two replies to /balance"

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
# R36 (D72): without a threshold too, a reply that answers nothing is an ordinary SMS
lw_uptime_add 601
n=$(sent)
sms_in 13 1466 '11/09/26 10:00:20' 'Imate: 0.10 do 05.01.; '
passes 2
expect_sent $((n + 1))
case $(last_text) in *'= Balance'*) lw_fail "reply without a query: $(last_text)" ;; esac
echo ok
