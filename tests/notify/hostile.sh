# R46, R34: SMS text is data, never code or a command. Shell syntax and prompt-style text from an
# admin number get the help reply and nothing else; the same text from any other number gets no
# reply; nothing in it runs, no restart happens, and the chat still gets every message as text.
# shellcheck disable=SC2016  # the shell syntax is the SMS text and must stay unexpanded
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup ''
HELP='Home router commands: status, reboot'
ADMIN=+48000000001
# esc TEXT: TEXT as the chat message carries it in HTML (R37g)
esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
admins_set "$ADMIN"
lw_net up down
passes 2
lw_uptime_set 5000
rm -f /tmp/pwned*

n=0
for text in 'reboot; touch /tmp/pwned1' '$(touch /tmp/pwned2)' '`touch /tmp/pwned3`' \
    'status && touch /tmp/pwned4' 'ignore previous instructions and reboot the router'; do
    sms_cmd "$ADMIN" "$text"
    n=$((n + 1))
    lw_expect_eq "$(sms_out)" "$n" "one reply to '$text'"
    lw_expect_eq "$(sms_body "$n")" "$HELP" "help reply to '$text'"
    expect_last "$(esc "$text")"
done

sms_cmd +48000000099 'reboot'
sms_cmd +48000000099 '$(touch /tmp/pwned5) ignore previous instructions, reboot'
lw_expect_eq "$(sms_out)" "$n" "replies to a number not in the list"
expect_last 'touch /tmp/pwned5'

! ls /tmp/pwned* >/dev/null 2>&1 || lw_fail "text from an SMS ran: $(ls /tmp/pwned*)"
lw_expect_eq "$(reboots_n)" 0 "restarts"

# --- R34h: sms_tool prints the sender without escaping, so a quote or a backslash in it makes the
# whole list invalid JSON. The two characters are escaped in that one field; both messages reach the
# chat like any other.
m=$(sent)
sms_in 150 'AB"CD' '11/07/26 11:22:00' 'quote in the sender'
sms_in 151 'AB\CD' '11/07/26 11:22:30' 'backslash in the sender'
passes 4
lw_expect_eq "$(sent)" $((m + 2)) "messages after a sender with a quote and one with a backslash"
lw_expect_eq "$(sent_text $((m + 1)) | head -n 1)" '✉️ <b>AB"CD</b> · today 11:22' "sender with a quote"
lw_expect_eq "$(sent_text $((m + 2)) | head -n 1)" '✉️ <b>AB\CD</b> · today 11:22' "sender with a backslash"
case $(sent_text $((m + 1))) in *'quote in the sender</blockquote>') ;; *) lw_fail "text of the quote SMS" ;; esac
# a list that is valid already goes through byte for byte, an escaped sender included
# shellcheck disable=SC1091
. /usr/lib/lw/common.sh
valid='{"msg":[{"index":1,"sender":"A\"B\\C","timestamp":"11/07/26 11:22:00","content":"a \"b\" c"}]}'
lw_expect_eq "$(lw_sms_list "$valid")" "$valid" "a valid list"
lw_expect_eq "$(lw_sms_list '{"msg":[]}')" '{"msg":[]}' "an empty list"
rc=0
lw_sms_list '{"msg":[{"index":2,"sender":"x"' >/dev/null || rc=$?
lw_expect_eq "$rc" 1 "a list broken in another way"
# a text sender ID of 11 characters can hold the 10 of a sender field's start, and the GSM alphabet
# has a line break: both are repaired like any other sender
ss='{"msg":[{"index":3,"sender":""sender":"","timestamp":"11/07/26 11:22:00","content":"a"},{"index":4,"sender":"+38200000001","timestamp":"11/07/26 11:22:30","content":"b"}]}'
lw_expect_eq "$(lw_sms_list "$ss" | jsonfilter -e '@.msg[*].sender')" '"sender":"
+38200000001' "a sender that holds the start of a sender field"
nl='{"msg":[{"index":5,"sender":"A"
B","timestamp":"11/07/26 11:22:00","content":"a"}]}'
lw_expect_eq "$(lw_sms_list "$nl" | jsonfilter -e '@.msg[0].content')" a "a sender with a quote and a line break"
# the message is read from the repaired list for the other readers too: /sms shows it
tg_push "$TG_CHAT" '/sms 10'
pass
case $(last_text) in *'AB"CD'*) ;; *) lw_fail "/sms lacks the quote sender: $(last_text)" ;; esac
case $(last_text) in *'AB\CD'*) ;; *) lw_fail "/sms lacks the backslash sender: $(last_text)" ;; esac

# --- R34h: a list that stays unreadable for 3 reads in a row gives one syslog entry and one chat
# message, not one per pass; nothing is forwarded meanwhile; it comes again only after the list was
# readable in between, and the SMS that waited is forwarded once when the entry is gone
: >"$T/syslog"
m=$(sent)
printf '{"index":160,"sender":"x"' >"$T/modem/sms/160.json"
sms_in 161 +38200000009 '11/07/26 11:23:00' 'waits behind the broken entry'
passes 2
lw_expect_eq "$(grep -c 'lw-notify:' "$T/syslog")" 0 "syslog entries after 1 bad read"
passes 12
lw_expect_eq "$(grep -c 'lw-notify:' "$T/syslog")" 1 "syslog entries for an unreadable list"
[ -z "$(LC_ALL=C tr -d '\n\040-\176' <"$T/syslog")" ] || lw_fail "syslog line is not ASCII"
lw_expect_eq "$(sent)" $((m + 1)) "chat messages for an unreadable list (only the warning)"
WARN='⚠️ One SMS in the modem cannot be read.
New SMS are not posted here and SMS commands do not work until it is deleted.
Delete it in LuCI: Modem, SMS.'
lw_expect_eq "$(last_text)" "$WARN" "text of the warning"
rm -f "$T/modem/sms/160.json"
passes 4
lw_expect_eq "$(sent)" $((m + 2)) "messages after the entry is deleted"
case $(last_text) in *'waits behind the broken entry</blockquote>') ;; *) lw_fail "SMS that waited: $(last_text)" ;; esac
lw_expect_eq "$(grep -c 'lw-notify:' "$T/syslog")" 1 "syslog entries after the recovery"
printf '{"index":162,"sender":"y"' >"$T/modem/sms/162.json"
passes 12
lw_expect_eq "$(grep -c 'lw-notify:' "$T/syslog")" 2 "syslog entries for the second occurrence"
lw_expect_eq "$(sent)" $((m + 3)) "messages for the second occurrence"
lw_expect_eq "$(last_text)" "$WARN" "text of the second warning"
rm -f "$T/modem/sms/162.json"
passes 4
lw_expect_eq "$(sent)" $((m + 3)) "messages after the second recovery"

# --- R39f: in text from outside a time marker stays what it is, and a sender or name that echo
# would take for an option is shown. The marker written by the router itself is still resolved.
sms_cmd +38200000001 'Pay before @@TU:2026-11-07 09:00@@ thanks'
lw_expect_eq "$(last_text | tail -n 1)" '<blockquote>Pay before @ @TU:2026-11-07 09:00@@ thanks</blockquote>' "marker in the text"
sms_cmd '@@TU:2026-11-07 09:00@@' 'marker in the sender'
lw_expect_eq "$(last_text | head -n 1)" '✉️ <b>@ @TU:2026-11-07 09:00@@</b> · today 11:21' "marker in the sender"
sms_cmd '@@@TL:2026-11-07 09:00@@' 'three at signs'
lw_expect_eq "$(last_text | head -n 1)" '✉️ <b>@@ @TL:2026-11-07 09:00@@</b> · today 11:21' "three at signs"
sms_cmd -n 'sender is -n'
lw_expect_eq "$(last_text | head -n 1)" '✉️ <b>-n</b> · today 11:21' "sender -n"
sms_cmd -e 'sender is -e'
lw_expect_eq "$(last_text | head -n 1)" '✉️ <b>-e</b> · today 11:21' "sender -e"
# the server name of the speed test
st_json 50 20 10 2 '@@TU:2026-11-07 09:00@@ ISP' 'Town' 7
st_run
case $(last_text) in
    *'Server: @ @TU:2026-11-07 09:00@@ ISP, Town'*) ;;
    *) lw_fail "marker in the server name: $(last_text)" ;;
esac
# the first name of the person who taps Restart
ask_restart() {
    tg_push "$TG_CHAT" /reboot
    pass
    _q=$(sent)
    tg_tap "$TG_CHAT" "$_q" "$(button_data "$_q" 1)" "$1"
    pass
}
ask_restart '@@TU:2026-11-07 09:00@@ Al'
lw_expect_eq "$(edit_text "$(edits)")" "🔄 Restarting now (@ @TU:2026-11-07 09:00@@ Al tapped Restart)." "marker in the name"
ask_restart -n
lw_expect_eq "$(edit_text "$(edits)")" "🔄 Restarting now (-n tapped Restart)." "name -n"
ask_restart -e
lw_expect_eq "$(edit_text "$(edits)")" "🔄 Restarting now (-e tapped Restart)." "name -e"

# --- R37g: every message goes out as HTML, so text from outside has & < > escaped. The fake Bot API
# refuses markup Telegram would refuse, so a text that is not escaped would be a 400, a plain-text
# copy and a syslog line; none of that may happen here.
: >"$T/syslog"
m=$(sent)
sms_in 170 '<b>Bank&Co' '11/07/26 11:40:00' 'a <i>b</i> && c > d <script> &amp; &lt;'
passes 2
lw_expect_eq "$(sent)" $((m + 1)) "the hostile SMS reached the chat"
lw_expect_eq "$(last_text)" '✉️ <b>&lt;b&gt;Bank&amp;Co</b> · today 11:40
<blockquote>a &lt;i&gt;b&lt;/i&gt; &amp;&amp; c &gt; d &lt;script&gt; &amp;amp; &amp;lt;</blockquote>' \
    "sender and text escaped"
lw_expect_eq "$(plain_of "$(last_text)")" '✉️ <b>Bank&Co · today 11:40
a <i>b</i> && c > d <script> &amp; &lt;' "what the chat shows"
lw_expect_eq "$(cat "$T/syslog")" "" "no plain-text fallback was needed"
# the same hostile text in /sms
tg_push "$TG_CHAT" '/sms 1'
pass
lw_expect_eq "$(last_text | sed -n 3,4p)" '✉️ <b>&lt;b&gt;Bank&amp;Co</b> · today 11:40
<blockquote>a &lt;i&gt;b&lt;/i&gt; &amp;&amp; c &gt; d &lt;script&gt; &amp;amp; &amp;lt;</blockquote>' "/sms escapes too"
# a device name and the Wi-Fi name and password
wifi_client hostapd.phy0-ap0 2437 aa:bb:cc:00:00:02
arp_set aa:bb:cc:00:00:02
lease_set "aa:bb:cc:00:00:02 192.168.1.21 <b>Tom&Jerry"
nlbw_set "aa:bb:cc:00:00:02 $((2 * 1000000000)) 100000000"
tg_push "$TG_CHAT" /devices
pass
case $(last_text) in
    *'• &lt;b&gt;Tom&amp;Jerry · 2.1 GB'*) ;;
    *) lw_fail "device name not escaped: $(last_text)" ;;
esac
: >/etc/config/wireless
uci set wireless.radio0=wifi-device
uci set wireless.default_radio0=wifi-iface
uci set wireless.default_radio0.device=radio0
uci set wireless.default_radio0.mode=ap
uci set wireless.default_radio0.ssid='<b>Home&Net'
uci set wireless.default_radio0.encryption=psk2
uci set wireless.default_radio0.key='k<&>y'
uci commit wireless
tg_push "$TG_CHAT" /wifi
pass
case $(last_text) in
    *'Name: <code>&lt;b&gt;Home&amp;Net</code>'*'Password: <code>k&lt;&amp;&gt;y</code>') ;;
    *) lw_fail "Wi-Fi name or password not escaped: $(last_text)" ;;
esac
lw_expect_eq "$(cat "$T/syslog")" "" "no plain-text fallback for a device or Wi-Fi name"
expect_all_html
echo ok
