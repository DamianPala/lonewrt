# R34 scenario 1: with internet, a new SMS reaches the chat with sender, modem time and content,
# and after a reboot it does not come a second time. Messages already in the store at the first
# start after a flash are not a backlog to forward. R34b: the list is read only after the count
# changed.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup ''

sms_in 0 +38200111222 '09/01/26 08:00:00' 'old message'
passes 3
expect_sent 0
[ -f /etc/lw-notify/seen ] || lw_fail "first run left no seen list"

sms_in 1 +38200000001 '11/07/26 10:24:42' 'Vas racun je dopunjen sa 10 Eur. Stanje 10 Eur.'
: >"$T/at-calls"
pass
expect_sent 0
lw_expect_grep "$T/at-calls" 'AT+CPMS?'
lw_expect_no_grep "$T/at-calls" 'recv'
pass
expect_sent 1
lw_expect_eq "$(sent_text 1)" "✉️ +38200000001 · Today 10:24

Vas racun je dopunjen sa 10 Eur. Stanje 10 Eur." "forwarded text"
[ -z "$(find /etc/lw-notify/queue -type f 2>/dev/null)" ] ||
    lw_fail "sent message left in the queue"

# an unchanged count reads no list
: >"$T/at-calls"
passes 3
lw_expect_no_grep "$T/at-calls" 'recv'
expect_sent 1

# reboot: /tmp is gone, the store and /etc stay; nothing comes twice
lw_reboot_sim
passes 4
expect_sent 1

# non-ASCII content arrives intact, two messages in store order
sms_in 2 1477 '11/07/26 11:00:00' 'Internet 500MB: 0.00MB, važi do 01.01.2222'
sms_in 3 +38200000002 '11/07/26 11:00:05' 'second & third = 100%'
passes 2
expect_sent 3
expect_last 'second & third = 100%'
case $(sent_text 2) in
    *'važi do 01.01.2222'*) ;;
    *) lw_fail "UTF-8 text changed: $(sent_text 2)" ;;
esac
lw_expect_eq "$(cat "$T/syslog")" "" "syslog after normal forwarding"
echo ok
