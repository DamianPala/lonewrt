# R47, R47a, R47b, D66: the operator preset. The SIM's IMSI (first 5 digits) picks a data file; the
# 29702 file reproduces what the code did before presets (labels, RACUN to 1466, the pattern, EUR);
# a SIM without a preset sends no SMS and says so; an IMSI that cannot be read yet is tried again
# later; a file that does not pass the strict reader is rejected with one log line; another preset
# changes currency, labels, query and pattern; a threshold is in the currency of the preset.
# All numbers are fake.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup 7.50
NOPRESET='💶 Balance: not available for this operator'

# imsi 5-DIGITS: the SIM the modem stub reports; reset_preset: what a service start forgets
imsi() { echo "${1}0000000123" >"$T/modem/imsi"; }
reset_preset() {
    rm -f /tmp/lw-notify/mccmnc /tmp/lw-notify/mccmnc_try /tmp/lw-notify/preset_bad \
        /tmp/lw-notify/balance_req
}
cimi_calls() { grep -c 'AT+CIMI' "$T/at-calls" || :; }
# ask_balance: /balance arrives and is answered
ask_balance() {
    tg_push "$TG_CHAT" /balance
    pass
}

# --- the 29702 file: Telekom Montenegro, as before
passes 3
expect_sent 0
lw_expect_eq "$(cimi_calls)" 1 "IMSI reads in three passes"
lw_expect_eq "$(cat /tmp/lw-notify/mccmnc)" 29702 "the 5 digits kept in RAM"
sms_in 1 1477 '11/07/26 11:00:00' 'Internet 500MB: 0.00MB, vazi do 01.01.2222'
sms_in 2 +38267123456 '11/07/26 11:01:00' 'plain number'
sms_in 3 1466 '11/07/26 11:02:00' 'Neka poruka'
sms_in 4 3030 '11/07/26 11:03:00' 'another short code'
passes 2
lw_expect_eq "$(sent_text 1 | head -n 1)" "✉️ Telekom 1477 · Today 11:00" "label of 1477"
lw_expect_eq "$(sent_text 2 | head -n 1)" "✉️ +38267123456 · Today 11:01" "plus on a long number"
lw_expect_eq "$(sent_text 3 | head -n 1)" "✉️ Telekom 1466 · Today 11:02" "label of 1466"
lw_expect_eq "$(sent_text 4 | head -n 1)" "✉️ 3030 · Today 11:03" "other short codes stay"
tg_push "$TG_CHAT" /help
pass
expect_last '/balance – ask Telekom for the balance (~1 min)'
ask_balance
lw_expect_eq "$(sms_out)" 1 "SMS for /balance"
lw_expect_eq "$(sms_to 1) $(sms_body 1)" "1466 RACUN" "the query"
expect_last '💶 Asked Telekom for the balance (SMS to 1466)'
lw_expect_eq "$(cimi_calls)" 1 "IMSI reads in all passes so far"
sms_in 5 1466 '11/07/26 11:05:00' 'Imate: 0.31 do 05.01.; Hvala'
passes 2
lw_expect_eq "$(last_text)" "✉️ Telekom 1466 · Today 11:05

Imate: 0.31 do 05.01.; Hvala
= Balance 0.31 EUR, credit valid until 5 Jan

⚠️ Low balance: 0.31 EUR (today 11:05)
Top up at least 7.50 EUR, or the data package will not renew." "balance answer"
# the answer of a number that is not the preset's sender is no balance
sms_in 6 +38200000007 '11/07/26 11:06:00' 'Imate: 0.01 do 05.01.; Hvala'
passes 2
lw_expect_eq "$(last_text)" "✉️ +38200000007 · Today 11:06

Imate: 0.01 do 05.01.; Hvala" "an answer from the wrong sender"
lw_expect_eq "$(cat /etc/lw-notify/lastbal)" "0.31|2026-11-07 11:05" "the wrong sender changed the balance"
tg_push "$TG_CHAT" /status
pass
expect_last '💶 Balance: 0.31 EUR (today 11:05)'
expect_last '   ⚠️ below 7.50 EUR needed for the next data month'
expect_last '⚠️ Top up at least 7.50 EUR'
tg_push "$TG_CHAT" /alerts
pass
expect_last 'Low balance: on'
lw-notify balance
lw_expect_eq "$(sms_out)" 2 "SMS of the weekly job"
lw_expect_eq "$(sms_to 2) $(sms_body 2)" "1466 RACUN" "the weekly query"
lw_expect_grep "$T/syslog" 'lw-notify: weekly balance check: RACUN sent to 1466'

# --- a card without a preset (26003): no SMS but replies of R46, the line in /status and /balance,
# plain senders, no balance rule, a silent weekly job
reset_preset
imsi 26003
rm -f /etc/lw-notify/lastbal /etc/lw-notify/balance
n=$(sms_out)
ask_balance
lw_expect_eq "$(last_text)" "$NOPRESET (26003)" "/balance without a preset"
lw_expect_eq "$(sms_out)" "$n" "SMS for /balance without a preset"
tg_push "$TG_CHAT" /status
pass
expect_last "$NOPRESET (26003)"
case $(last_text) in *'Top up'* | *'below'*) lw_fail "balance advice without a preset: $(last_text)" ;; esac
case $(last_text) in *'✅ Nothing to do'*) ;; *) lw_fail "action line: $(last_text)" ;; esac
tg_push "$TG_CHAT" /help
pass
expect_last '/balance – the balance check is not available for this SIM'
tg_push "$TG_CHAT" /alerts
pass
expect_last 'Low balance: off'
sms_in 10 1466 '11/07/26 11:30:00' 'Imate: 0.20 do 05.01.; Hvala'
sms_in 11 1477 '11/07/26 11:31:00' 'info'
sms_in 12 +38200000007 '11/07/26 11:32:00' 'long number'
passes 2
lw_expect_eq "$(sent_text $(($(sent) - 2)))" "✉️ 1466 · Today 11:30

Imate: 0.20 do 05.01.; Hvala" "1466 without a preset: plain, no translation, no warning"
lw_expect_eq "$(sent_text $(($(sent) - 1)) | head -n 1)" "✉️ 1477 · Today 11:31" "1477 without a preset"
lw_expect_eq "$(sent_text "$(sent)" | head -n 1)" "✉️ +38200000007 · Today 11:32" "long number"
[ ! -e /etc/lw-notify/lastbal ] || lw_fail "a balance was kept without a preset"
lw-notify balance
lw_expect_eq "$(sms_out)" "$n" "SMS of the weekly job without a preset"
lw_expect_grep "$T/syslog" 'weekly balance check skipped: no operator preset'
ADMIN=+48000000001
admins_set "$ADMIN"
sms_cmd 48000000001 STATUS
case $(sms_body "$(sms_out)") in
    'Home router: internet '*) ;;
    *) lw_fail "STATUS text: $(sms_body "$(sms_out)")" ;;
esac
case $(sms_body "$(sms_out)") in *alance*) lw_fail "balance in STATUS without a preset" ;; esac
lw_expect_eq "$(sms_out)" $((n + 1)) "SMS after one STATUS"
admins_set ''

# --- an IMSI that cannot be read at first: no preset yet, tried again later (not every pass), then
# the preset is there. R47a holds meanwhile
reset_preset
imsi 29702
lw_at_override AT+CIMI SILENT
: >"$T/at-calls"
n=$(sms_out)
passes 5
lw_expect_eq "$(cimi_calls)" 1 "IMSI reads while the modem is silent"
ask_balance
lw_expect_eq "$(last_text)" "$NOPRESET (unknown)" "/balance before the IMSI is known"
lw_expect_eq "$(sms_out)" "$n" "SMS before the IMSI is known"
rm -f "$T/at/AT_CIMI"
passes 3
lw_expect_eq "$(cimi_calls)" 1 "IMSI reads inside the retry time"
lw_uptime_add 61
wall_add 61
pass
lw_expect_eq "$(cimi_calls)" 2 "IMSI reads after the retry time"
ask_balance
lw_expect_eq "$(sms_out)" $((n + 1)) "SMS after the IMSI is known"
lw_expect_eq "$(sms_to $((n + 1))) $(sms_body $((n + 1)))" "1466 RACUN" "the query after the IMSI is known"
# a busy lock is no read at all, and no wait
reset_preset
flock /tmp/lw-at.lock sleep 3 &
holder=$!
sleep 1
: >"$T/at-calls"
t0=$(date +%s)
passes 2
[ "$(elapsed_since "$t0")" -le 2 ] || lw_fail "the IMSI read waited for the lock"
lw_expect_eq "$(cimi_calls)" 0 "IMSI reads through a busy lock"
wait "$holder"
lw_uptime_add 61
wall_add 61
pass
lw_expect_eq "$(cimi_calls)" 1 "IMSI read when the lock is free"

# the real service loop: started with a silent modem, it finds the IMSI later
reset_preset
lw_at_override AT+CIMI SILENT
export LW_NOTIFY_CLOCK=/proc/uptime LW_NOTIFY_POLL=1 LW_NOTIFY_LONGPOLL=1 LW_NOTIFY_PRESET_RETRY=2
unset LW_NOTIFY_WALL
lw-notify run </dev/null >/dev/null 2>&1 &
svc=$!
sleep 2
n=$(sms_out)
tg_push "$TG_CHAT" /balance
i=0
until [ "$(sent)" -ge 1 ] && [ "$(last_text)" != "" ] && case $(last_text) in *'(unknown)'*) true ;; *) false ;; esac || [ "$i" -ge 8 ]; do
    sleep 1
    i=$((i + 1))
done
expect_last "$NOPRESET (unknown)"
rm -f "$T/at/AT_CIMI"
sleep 4
tg_push "$TG_CHAT" /balance
i=0
until [ "$(sms_out)" -gt "$n" ] || [ "$i" -ge 8 ]; do
    sleep 1
    i=$((i + 1))
done
lw_expect_eq "$(sms_out)" $((n + 1)) "SMS from the service after the IMSI came"
kill "$svc"
wait "$svc" || :
no_orphans

# --- files that do not pass the strict reader: one log line, treated as no preset, nothing run
export LW_NOTIFY_CLOCK="$T/uptime" LW_NOTIFY_POLL=0 LW_NOTIFY_WALL="$T/wall"
unset LW_NOTIFY_PRESET_RETRY
# the service ran on the real uptime: what it kept in RAM is stamped with that clock, and RAM is
# empty after a restart anyway
rm -f "$T/at/AT_CIMI"
rm -rf /tmp/lw-notify
passes 3
OPS=/opt/ops
mkdir -p "$OPS"
export LW_OPERATORS_DIR=$OPS
GOOD=$(cat /usr/share/lw/operators/29702)
rm -f /tmp/pwned*

# bad_case LABEL: the preset text on stdin
bad_case() {
    reset_preset
    imsi 29702
    cat >"$OPS/29702"
    n=$(sms_out)
    lines=$(grep -c 'operator preset 29702 rejected' "$T/syslog" || :)
    ask_balance
    lw_expect_eq "$(last_text)" "$NOPRESET (29702)" "$1: /balance"
    passes 3
    lw_expect_eq "$(grep -c 'operator preset 29702 rejected' "$T/syslog" || :)" $((lines + 1)) \
        "$1: log lines"
    lw-notify balance
    lw_expect_eq "$(sms_out)" "$n" "$1: SMS sent"
    ! ls /tmp/pwned* >/dev/null 2>&1 || lw_fail "$1: a command in the file was run"
    case $(grep 'operator preset 29702 rejected' "$T/syslog" | tail -n 1) in
        *pwned* | *'$'* | *'`'*) lw_fail "$1: the log line shows a value: $(tail -n 1 "$T/syslog")" ;;
    esac
}
printf '%s\n' "$GOOD" "FOO='x'" | bad_case "unknown key"
printf '%s\n' "$GOOD" "CURRENCY='USD'" | bad_case "key twice"
printf '%s\n' "$GOOD" "touch /tmp/pwned1" | bad_case "a command line"
printf '%s\n' "$GOOD" "export CURRENCY=EUR" | bad_case "export line"
printf '%s\n' "$GOOD" "CURRENCY='EUR'; touch /tmp/pwned2" | bad_case "command after the value"
printf '%s\n' "$GOOD" "SHORT_CODES='1 2' ; touch /tmp/pwned3 '" | bad_case "quote trick"
printf '%s\n' "$GOOD" "SHORT_CODES='\$(touch /tmp/pwned4)'" | bad_case "command substitution"
printf '%s\n' "$GOOD" "SHORT_CODES='\`touch /tmp/pwned5\`'" | bad_case "backticks"
printf '%s\n' "$GOOD" "SHORT_CODES='\${PATH}'" | bad_case "variable"
printf '%s\n' "$GOOD" "SHORT_CODES='a;touch /tmp/pwned6'" | bad_case "semicolon in a value"
printf '%s\n' "$GOOD" "SHORT_CODES='a b" | bad_case "missing closing quote"
printf '%s\n' "$GOOD" "SHORT_CODES=1466" | bad_case "no quotes"
printf '%s\n' "$GOOD" "SHORT_CODES='it's'" | bad_case "quote inside"
printf '%s\n' "$GOOD" "short_codes='1466'" | bad_case "lower case key"
printf '%s\n' "$GOOD" " SHORT_CODES='1466'" | bad_case "leading space"
printf '%s\r\n' "$GOOD" | bad_case "CRLF"
printf '%s\n' "$GOOD" | grep -v '^CURRENCY' | bad_case "missing CURRENCY"
printf '%s\n' "$GOOD" | grep -v '^BALANCE_QUERY_TEXT' | bad_case "missing query text"
printf '%s\n' "$GOOD" | grep -v '^BALANCE_REPLY_PATTERN' | bad_case "missing pattern"
printf '%s\n' "$GOOD" | grep -v '^OPERATOR_NAME' | bad_case "missing name"
printf '%s\n' "$GOOD" | sed "s/^CURRENCY=.*/CURRENCY='eur'/" | bad_case "currency in lower case"
printf '%s\n' "$GOOD" | sed "s/^CURRENCY=.*/CURRENCY='EURO'/" | bad_case "currency of 4 letters"
printf '%s\n' "$GOOD" | sed "s/^OPERATOR_NAME=.*/OPERATOR_NAME='A very long operator name'/" | bad_case "long name"
printf '%s\n' "$GOOD" | sed "s/^OPERATOR_NAME=.*/OPERATOR_NAME='\$(touch \/tmp\/pwned7)'/" | bad_case "name with a command"
printf '%s\n' "$GOOD" | sed "s/^OPERATOR_NAME=.*/OPERATOR_NAME=''/" | bad_case "empty name"
printf '%s\n' "$GOOD" | sed "s/^BALANCE_QUERY_TEXT=.*/BALANCE_QUERY_TEXT='-h'/" | bad_case "query text that is an option"
printf '%s\n' "$GOOD" | sed "s/^BALANCE_QUERY_NUMBER=.*/BALANCE_QUERY_NUMBER='14 66'/" | bad_case "number with a space"
printf '%s\n' "$GOOD" | sed "s/^BALANCE_QUERY_NUMBER=.*/BALANCE_QUERY_NUMBER='14'/" | bad_case "number too short"
printf '%s\n' "$GOOD" | sed "s/^BALANCE_REPLY_PATTERN=.*/BALANCE_REPLY_PATTERN='Imate: do {day}.{month}.'/" | bad_case "pattern without amount"
printf '%s\n' "$GOOD" | sed "s/^BALANCE_REPLY_PATTERN=.*/BALANCE_REPLY_PATTERN='Imate: {amount} {amount}'/" | bad_case "amount twice"
printf '%s\n' "$GOOD" | sed "s/^BALANCE_REPLY_PATTERN=.*/BALANCE_REPLY_PATTERN='Imate: {amount} do {day}.'/" | bad_case "day without month"
printf '%s\n' "$GOOD" | sed "s/^BALANCE_REPLY_PATTERN=.*/BALANCE_REPLY_PATTERN='Imate: {amount} {year}'/" | bad_case "unknown placeholder"
printf '%s\n' "$GOOD" | sed "s/^BALANCE_REPLY_PATTERN=.*/BALANCE_REPLY_PATTERN='Imate: {amount'/" | bad_case "open brace"
printf '%s\n' "$GOOD" | sed "s/^BALANCE_REPLY_PATTERN=.*/BALANCE_REPLY_PATTERN='Imate: [0-9]*{amount}'/" | bad_case "regex in the pattern"
printf '%s\n' "$GOOD" | sed "s/^BALANCE_REPLY_PATTERN=.*/BALANCE_REPLY_PATTERN='Imate: \\\\1 {amount}'/" | bad_case "backslash in the pattern"
printf '%s\n' "$GOOD" | sed "s/^BALANCE_REPLY_PATTERN=.*/BALANCE_REPLY_PATTERN='Imate: {amount} #x'/" | bad_case "sed delimiter in the pattern"
# {any} is greedy and would eat the leading digits of a number that follows it
printf '%s\n' "$GOOD" | sed "s/^BALANCE_REPLY_PATTERN=.*/BALANCE_REPLY_PATTERN='Imate: {any}{amount}'/" | bad_case "any right before amount"
printf '%s\n' "$GOOD" | sed "s/^BALANCE_REPLY_PATTERN=.*/BALANCE_REPLY_PATTERN='Balance {any} {amount} EUR'/" | bad_case "any, space, amount"
printf '%s\n' "$GOOD" | sed "s/^BALANCE_REPLY_PATTERN=.*/BALANCE_REPLY_PATTERN='Imate: {amount} {any}{day}.{month}'/" | bad_case "any right before day and month"
printf '%s\n' "$GOOD" | sed "s/^BALANCE_REPLY_PATTERN=.*/BALANCE_REPLY_PATTERN='Imate: {amount} {any}  {month}.{day}'/" | bad_case "any, spaces, month"
# R47c: the same when only characters of a number (digits, dot, comma) and spaces stand between
# {any} and the number: "12.50" read by {any}.{amount} would give 50
printf '%s\n' "$GOOD" | sed "s/^BALANCE_REPLY_PATTERN=.*/BALANCE_REPLY_PATTERN='Saldo {any}.{amount}'/" | bad_case "any, dot, amount"
printf '%s\n' "$GOOD" | sed "s/^BALANCE_REPLY_PATTERN=.*/BALANCE_REPLY_PATTERN='Saldo {any},{amount}'/" | bad_case "any, comma, amount"
printf '%s\n' "$GOOD" | sed "s/^BALANCE_REPLY_PATTERN=.*/BALANCE_REPLY_PATTERN='Saldo {any} . {amount}'/" | bad_case "any, spaced dot, amount"
printf '%s\n' "$GOOD" | sed "s/^BALANCE_REPLY_PATTERN=.*/BALANCE_REPLY_PATTERN='Saldo {any}0{amount}'/" | bad_case "any, digit, amount"
printf '%s\n' "$GOOD" | sed "s/^BALANCE_REPLY_PATTERN=.*/BALANCE_REPLY_PATTERN='Saldo {any}.,{amount}'/" | bad_case "any, dot and comma, amount"
printf '%s\n' "$GOOD" | sed "s/^BALANCE_REPLY_PATTERN=.*/BALANCE_REPLY_PATTERN='Saldo {amount} do {any}.{day}.{month}'/" | bad_case "any, dot, day"
printf '%s\n' "$GOOD" | sed "s/^BALANCE_REPLY_PATTERN=.*/BALANCE_REPLY_PATTERN='Saldo {any}.{any}{amount}'/" | bad_case "any, dot, any, amount"
{ printf '%s\n' "$GOOD"; i=0; while [ "$i" -lt 150 ]; do echo '# padding padding padding padding padding padding padding'; i=$((i + 1)); done; } |
    bad_case "file over 4096 bytes"
printf '' | bad_case "empty file"
echo "# only a comment" | bad_case "only a comment"
# a bad file leaves the other cards alone: 26003 has no file at all, and says nothing in the log
reset_preset
imsi 26003
lines=$(grep -c 'operator preset' "$T/syslog" || :)
ask_balance
lw_expect_eq "$(last_text)" "$NOPRESET (26003)" "no file"
lw_expect_eq "$(grep -c 'operator preset' "$T/syslog" || :)" "$lines" "log lines for a card without a file"
# only 5 digits pick a file: a cached MCC-MNC of another shape is dropped and the IMSI read again
reset_preset
imsi 26003
echo '../29702' >/tmp/lw-notify/mccmnc
ask_balance
lw_expect_eq "$(last_text)" "$NOPRESET (26003)" "a cached MCC-MNC that is not 5 digits"

# a valid file with comments, blank lines, no final newline and every key in another order
reset_preset
imsi 29702
n=$(sms_out)
printf '# my operator\n\nSHORT_CODES='"'"'1466 1477'"'"'\nCURRENCY='"'"'EUR'"'"'\nBALANCE_REPLY_PATTERN='"'"'Imate: {amount} do {day}.{month}.'"'"'\nBALANCE_REPLY_FROM='"'"'1466'"'"'\nBALANCE_QUERY_TEXT='"'"'RACUN'"'"'\nBALANCE_QUERY_NUMBER='"'"'1466'"'"'\nOPERATOR_NAME='"'"'Telekom'"'"'' \
    >"$OPS/29702"
ask_balance
lw_expect_eq "$(sms_out)" $((n + 1)) "a valid file in another order"
# SHORT_CODES is optional: without it a short code shows as the plain number
printf '%s\n' "$GOOD" | grep -v '^SHORT_CODES' >"$OPS/29702"
reset_preset
sms_in 40 1477 '11/07/26 11:40:00' 'info'
passes 3
lw_expect_eq "$(last_text | head -n 1)" "✉️ 1477 · Today 11:40" "a preset without SHORT_CODES"

# --- another operator: currency, labels, query, pattern with the date as month/day
printf '%s\n' "OPERATOR_NAME='Acme Mobile'" "CURRENCY='USD'" "BALANCE_QUERY_NUMBER='4040'" \
    "BALANCE_QUERY_TEXT='BAL'" "BALANCE_REPLY_FROM='ACME'" \
    "BALANCE_REPLY_PATTERN='Your balance is {amount} USD, valid till {month}/{day}'" \
    "SHORT_CODES='4040 4041'" >"$OPS/99999"
reset_preset
imsi 99999
rm -f /etc/lw-notify/lastbal /etc/lw-notify/balance
n=$(sms_out)
tg_push "$TG_CHAT" /help
pass
expect_last '/balance – ask Acme Mobile for the balance (~1 min)'
ask_balance
lw_expect_eq "$(sms_out)" $((n + 1)) "SMS for /balance with another preset"
lw_expect_eq "$(sms_to $((n + 1))) $(sms_body $((n + 1)))" "4040 BAL" "the query of the other preset"
expect_last '💶 Asked Acme Mobile for the balance (SMS to 4040)'
sms_in 20 4040 '11/07/26 12:00:00' 'hello from the short code'
sms_in 21 1466 '11/07/26 12:01:00' 'not a Telekom code here'
passes 2
lw_expect_eq "$(sent_text $(($(sent) - 1)) | head -n 1)" "✉️ Acme Mobile 4040 · Today 12:00" "label of 4040"
lw_expect_eq "$(sent_text "$(sent)" | head -n 1)" "✉️ 1466 · Today 12:01" "1466 has no label here"
sms_in 22 ACME '11/07/26 12:02:00' 'Your balance is 3,20 USD, valid till 3/27'
passes 2
lw_expect_eq "$(last_text)" "✉️ ACME · Today 12:02

Your balance is 3,20 USD, valid till 3/27
= Balance 3.20 USD, credit valid until 27 Mar

⚠️ Low balance: 3.20 USD (today 12:02)
Top up at least 7.50 USD, or the data package will not renew." "balance answer, USD"
sms_in 23 4040 '11/07/26 12:03:00' 'Your balance is 1.00 USD, valid till 3/27'
passes 2
lw_expect_eq "$(last_text)" "✉️ Acme Mobile 4040 · Today 12:03

Your balance is 1.00 USD, valid till 3/27" "the pattern from the wrong sender"
tg_push "$TG_CHAT" /status
pass
expect_last '💶 Balance: 3.20 USD (today 12:02)'
expect_last '   ⚠️ below 7.50 USD needed for the next data month'
expect_last '⚠️ Top up at least 7.50 USD'
case $(last_text) in *EUR*) lw_fail "EUR in /status of a USD preset: $(last_text)" ;; esac
lw-notify balance
lw_expect_eq "$(sms_to $((n + 2))) $(sms_body $((n + 2)))" "4040 BAL" "the weekly query of the other preset"
lw_expect_grep "$T/syslog" 'weekly balance check: BAL sent to 4040'
# above the threshold: an unasked reply is only recorded; asked for, it is forwarded and
# translated, with no low-balance warning
n=$(sent)
sms_in 24 ACME '11/07/26 12:10:00' 'Your balance is 12.00 USD, valid till 4/01'
passes 2
lw_expect_eq "$(sent)" "$n" "an unasked answer above the threshold"
lw_expect_eq "$(cat /etc/lw-notify/lastbal)" "12.00|2026-11-07 12:10" "balance kept"
ask_balance
sms_in 25 ACME '11/07/26 12:11:00' 'Your balance is 11.50 USD, valid till 4/01'
passes 2
lw_expect_eq "$(last_text)" "✉️ ACME · Today 12:11

Your balance is 11.50 USD, valid till 4/01
= Balance 11.50 USD, credit valid until 1 Apr" "an asked answer above the threshold"
# a pattern without a date and with {any}
printf '%s\n' "OPERATOR_NAME='Acme Mobile'" "CURRENCY='EUR'" "BALANCE_QUERY_NUMBER='+15550100'" \
    "BALANCE_QUERY_TEXT='STATE'" "BALANCE_REPLY_FROM='+15550100'" \
    "BALANCE_REPLY_PATTERN='Saldo: {amount} {any}'" >"$OPS/99998"
reset_preset
imsi 99998
n=$(sms_out)
ask_balance
lw_expect_eq "$(sms_to $((n + 1))) $(sms_body $((n + 1)))" "15550100 STATE" "query to a number written with a plus"
sms_in 30 +15550100 '11/07/26 12:20:00' 'Saldo: 9.99 EUR, hvala'
passes 2
lw_expect_eq "$(last_text)" "✉️ +15550100 · Today 12:20

Saldo: 9.99 EUR, hvala
= Balance 9.99 EUR" "pattern without a date"
# {any} followed by fixed text and then the number reads the whole number (not its last digit)
printf '%s\n' "OPERATOR_NAME='Acme Mobile'" "CURRENCY='EUR'" "BALANCE_QUERY_NUMBER='4040'" \
    "BALANCE_QUERY_TEXT='STATE'" "BALANCE_REPLY_FROM='ACME'" \
    "BALANCE_REPLY_PATTERN='Stanje {any} iznosi {amount} EUR, vazi do {any} dana {day}.{month}.'" \
    >"$OPS/99997"
reset_preset
imsi 99997
ask_balance
sms_in 31 ACME '11/07/26 12:30:00' 'Stanje na racunu iznosi 12.40 EUR, vazi do 5 dana 15.03.'
passes 2
lw_expect_eq "$(last_text)" "✉️ ACME · Today 12:30

Stanje na racunu iznosi 12.40 EUR, vazi do 5 dana 15.03.
= Balance 12.40 EUR, credit valid until 15 Mar" "any before fixed text"
# R47c: any other character between {any} and the number is enough (a colon, a letter), and a
# pattern that ends in {any} or has {any} before a name still passes: the whole number is read
printf '%s\n' "OPERATOR_NAME='Acme Mobile'" "CURRENCY='EUR'" "BALANCE_QUERY_NUMBER='4040'" \
    "BALANCE_QUERY_TEXT='STATE'" "BALANCE_REPLY_FROM='ACME'" \
    "BALANCE_REPLY_PATTERN='Saldo{any}:{amount} EUR'" >"$OPS/99996"
reset_preset
imsi 99996
ask_balance
sms_in 32 ACME '11/07/26 12:40:00' 'Saldo racuna:112.50 EUR'
passes 2
lw_expect_eq "$(last_text)" "✉️ ACME · Today 12:40

Saldo racuna:112.50 EUR
= Balance 112.50 EUR" "any, colon, amount"
no_orphans
echo ok
