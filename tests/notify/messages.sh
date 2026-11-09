# R39, R39a, R39b: how a forwarded SMS reads. Sender: 9 or more digits get a "+", 1466 and 1477 are
# Telekom, the rest stays as it is. The balance reply gets the translation line, other SMS none.
# Times: Today, Yesterday, "5 Nov 09:12", chosen when the message is sent, so one that waited in
# the queue past midnight says the right day. Plain text, no log lines or key=value in the text,
# and nothing but ASCII in the syslog (R29b).
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup 7.50
passes 3

# first_line N: the header of the Nth message
first_line() { sent_text "$1" | head -n 1; }

# R39a: each sender case
sms_in 0 38200000099 '11/07/26 11:11:00' 'To jest testowa wiadomost SMS.'
sms_in 1 123456789 '11/07/26 11:12:00' 'nine digits'
sms_in 2 12345678 '11/07/26 11:13:00' 'eight digits'
sms_in 3 1466 '11/07/26 11:14:00' 'Usluga nije dostupna.'
sms_in 4 1477 '11/07/26 11:15:00' 'Internet 500MB.'
sms_in 5 +38200000099 '11/07/26 11:16:00' 'already with a plus'
sms_in 6 Telenor '11/07/26 11:17:00' 'a name'
sms_in 7 '' '11/07/26 11:18:00' 'no sender'
passes 2
expect_sent 8
lw_expect_eq "$(sent_text 1)" "✉️ +38200000099 · Today 11:11

To jest testowa wiadomost SMS." "digits only, 11 of them"
lw_expect_eq "$(first_line 2)" "✉️ +123456789 · Today 11:12" "nine digits"
lw_expect_eq "$(first_line 3)" "✉️ 12345678 · Today 11:13" "eight digits"
lw_expect_eq "$(first_line 4)" "✉️ Telekom 1466 · Today 11:14" "1466"
lw_expect_eq "$(first_line 5)" "✉️ Telekom 1477 · Today 11:15" "1477"
lw_expect_eq "$(first_line 6)" "✉️ +38200000099 · Today 11:16" "plus kept"
lw_expect_eq "$(first_line 7)" "✉️ Telenor · Today 11:17" "a name"
lw_expect_eq "$(first_line 8)" "✉️ unknown · Today 11:18" "no sender"
# no translation for the others
for i in 1 2 3 4 5 6 7 8; do
    case $(sent_text "$i") in *'= Balance'*) lw_fail "translation under message $i" ;; esac
done

# R39b: the balance reply (the SPEC example, below the threshold, so with the warning); answers to
# /balance with a comma amount, a date at the end of a month and a date that makes no sense
ask_balance() {
    tg_push "$TG_CHAT" /balance
    pass
}
balance_asked
sms_in 10 1466 '11/07/26 11:05:00' 'Imate: 0.31 do 05.01.; '
passes 2
lw_expect_eq "$(last_text)" "✉️ Telekom 1466 · Today 11:05

Imate: 0.31 do 05.01.; 
= Balance 0.31 EUR, credit valid until 5 Jan

⚠️ Low balance: 0.31 EUR (today 11:05)
Top up at least 7.50 EUR, or the data package will not renew." "balance reply"
ask_balance
sms_in 11 1466 '11/07/26 11:06:00' 'Imate: 12,50 do 31.12.;'
passes 2
lw_expect_eq "$(last_text)" "✉️ Telekom 1466 · Today 11:06

Imate: 12,50 do 31.12.;
= Balance 12.50 EUR, credit valid until 31 Dec" "comma amount"
ask_balance
sms_in 12 1466 '11/07/26 11:07:00' 'Imate: 13.00 do 99.99.;'
passes 2
expect_last '= Balance 13.00 EUR, credit valid until unknown'

# R39: Today, Yesterday and "5 Nov 09:12", and a date of another year
sms_in 20 +38200000001 '11/06/26 18:40:00' 'yesterday'
sms_in 21 +38200000001 '11/05/26 09:12:00' 'earlier'
sms_in 22 +38200000001 '12/31/25 23:59:00' 'last year'
sms_in 23 +38200000001 '' 'no time'
passes 2
n=$(sent)
lw_expect_eq "$(sent_text $((n - 3)) | head -n 1)" "✉️ +38200000001 · Yesterday 18:40" "yesterday"
lw_expect_eq "$(sent_text $((n - 2)) | head -n 1)" "✉️ +38200000001 · 5 Nov 09:12" "earlier"
lw_expect_eq "$(sent_text $((n - 1)) | head -n 1)" "✉️ +38200000001 · 31 Dec 2025 23:59" "year"
lw_expect_eq "$(sent_text "$n" | head -n 1)" "✉️ +38200000001 · unknown" "no time"

# the day is chosen when the message is sent: queued at 23:50, sent after midnight
echo down >"$G/net"
wall_set '2026-11-07 23:50'
sms_in 30 +38200000002 '11/07/26 23:45:00' 'while offline'
passes 3
lw_expect_eq "$(sent)" "$n" "sent while Telegram is down"
wall_set '2026-11-08 00:10'
echo up >"$G/net"
pass
lw_expect_eq "$(first_line $((n + 1)))" "✉️ +38200000002 · Yesterday 23:45" "queued past midnight"
# a clock that ntpd has not synced cannot tell the day: the plain date
lw_reboot_sim
ntp_off
echo down >"$G/net"
sms_in 31 +38200000002 '11/08/26 00:12:00' 'unsynced'
passes 4
echo up >"$G/net"
pass
lw_expect_eq "$(first_line $((n + 2)))" "✉️ +38200000002 · 8 Nov 00:12" "unsynced clock"

# no marker is left in a message, no key=value or log line, and plain text only
for f in "$G"/sent/*.text; do
    case $(cat "$f") in *'@@'*) lw_fail "time marker in $f" ;; esac
done
! grep -q parse_mode /usr/sbin/lw-notify /usr/lib/lw/notify.sh || lw_fail "parse_mode set"
lw_expect_eq "$(LC_ALL=C grep -c '[^ -~]' "$T/syslog")" 0 "non-ASCII syslog lines"
echo ok
