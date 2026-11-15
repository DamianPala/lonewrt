# R37g, D83, D85: every message is sent with parse_mode=HTML. A long /sms is cut between messages,
# never inside a tag or an entity. When Telegram answers 400 to the HTML message (a fault in our own
# markup), the same text goes out once more as plain text, tags removed and entities decoded, and one
# lw-notify syslog line says so (ASCII, no token, no SMS text). An edit that is rejected does not
# lose the balance: it goes as a new message. The fake Bot API checks the markup like Telegram does
# (tests/notify/stubs/uclient-fetch), so a text that is not valid HTML is a 400 here too.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup 7.50
passes 2
FELL_BACK='lw-notify: Telegram rejected a message as HTML (HTTP 400), it went out as plain text'

# --- every kind of message has parse_mode HTML, none needs the fallback
sms_in 1 '<b>Bank&Co' '11/07/26 11:40:00' 'a <i>b</i> && c'
passes 2
for c in /help /status /wifi /devices /alerts '/sms 3'; do
    tg_push "$TG_CHAT" "$c"
    pass
done
expect_all_html
lw_expect_eq "$(cat "$T/syslog")" "" "syslog after messages that parsed"
lw_expect_eq "$(rejected_n)" 0 "rejections after messages that parsed"

# --- a long /sms is cut between messages: no chunk has an open tag or half an entity
long=$(printf 'x&y<z>%.0s' $(seq 1 90))
i=0
while [ "$i" -lt 10 ]; do
    sms_in $((100 + i)) +3820000000$i "11/07/26 12:0$i:00" "m$i $long"
    i=$((i + 1))
done
n=$(sent)
tg_push "$TG_CHAT" '/sms 10'
pass
chunks=$(($(sent) - n))
[ "$chunks" -ge 2 ] || lw_fail "a long /sms is one message ($chunks): the cut is not tested"
for k in $(seq $((n + 1)) $((n + chunks))); do
    t=$(sent_text "$k")
    lw_expect_eq "$(mode_of "$k")" HTML "parse_mode of chunk $k"
    lw_expect_eq "$(printf '%s\n' "$t" | grep -o '<blockquote>' | wc -l | tr -d ' ')" \
        "$(printf '%s\n' "$t" | grep -o '</blockquote>' | wc -l | tr -d ' ')" "blockquote tags in chunk $k"
    case $t in *'</blockquote>') ;; *) lw_fail "chunk $k does not end with a closed quote" ;; esac
    # an entity is whole: every & is followed by amp; lt; gt; and nothing else
    [ -z "$(printf '%s\n' "$t" | grep -o '&[^;]\{0,5\}' | grep -v '^&\(amp\|lt\|gt\)$' | grep -v '^&\(amp\|lt\|gt\);')" ] ||
        lw_fail "a cut entity in chunk $k"
done
lw_expect_eq "$(cat "$T/syslog")" "" "syslog after the long /sms"
lw_expect_eq "$(rejected_n)" 0 "rejections after the long /sms"
for f in "$T"/modem/sms/1[0-9][0-9].json; do rm -f "$f"; done

# --- Telegram says 400 to the HTML message: plain text, one log line, no SMS text in the log
echo html >"$G/reject400"
sms_in 2 '<b>Bank&Co' '11/07/26 12:30:00' 'a <i>b</i> && c > d'
n=$(sent)
r=$(rejected_n)
passes 2
lw_expect_eq "$(sent)" $((n + 1)) "the message went out once"
lw_expect_eq "$(rejected_n)" $((r + 1)) "one rejection, the plain text was taken"
lw_expect_eq "$(mode_of "$(sent)")" "" "the fallback has no parse_mode"
lw_expect_eq "$(last_text)" '✉️ <b>Bank&Co · today 12:30
a <i>b</i> && c > d' "plain text: tags removed, entities decoded"
lw_expect_eq "$(wc -l <"$T/syslog" | tr -d ' ')" 1 "syslog lines"
lw_expect_grep "$T/syslog" "$FELL_BACK"
lw_expect_no_grep "$T/syslog" Bank
lw_expect_no_grep "$T/syslog" "$TG_TOKEN"
[ -z "$(LC_ALL=C tr -d '\n\040-\176' <"$T/syslog")" ] || lw_fail "syslog line is not ASCII"
[ ! -e /tmp/lw-notify/down ] && [ ! -e /tmp/lw-notify/fail_since ] ||
    lw_fail "a 400 changed the link state"
lw_expect_eq "$(find /etc/lw-notify/queue -type f 2>/dev/null | wc -l | tr -d ' ')" 0 "queue"
# a command reply falls back the same way
: >"$T/syslog"
tg_push "$TG_CHAT" /alerts
pass
lw_expect_eq "$(last_text)" '🔔 Automatic messages
✅ New SMS
✅ Low balance
✅ Internet back
✅ 2G backup

Only the 2G message can be turned off.' "a command reply as plain text"
lw_expect_grep "$T/syslog" "$FELL_BACK"
rm -f "$G/reject400"

# --- the balance answer edits the acknowledgement; when Telegram refuses the edit, it is sent as a
# new message and the balance is not lost
tg_push "$TG_CHAT" /balance
pass
n=$(sent)
echo edit >"$G/reject400"
sms_in 3 1466 '11/07/26 12:40:00' 'Imate: 12.40 do 05.01.; '
passes 2
lw_expect_eq "$(sent)" $((n + 1)) "the answer went out as a new message"
lw_expect_eq "$(mode_of "$(sent)")" HTML "the new message is HTML"
case $(last_text) in
    '💶 <b>Balance: 12.40 EUR</b>, valid until 5 Jan'*) ;;
    *) lw_fail "balance answer: $(last_text)" ;;
esac
lw_expect_eq "$(find /etc/lw-notify/queue -type f 2>/dev/null | wc -l | tr -d ' ')" 0 "queue after the edit fell back"
no_orphans
echo ok
