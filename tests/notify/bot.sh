# R37, R37b: commands from the configured (group) chat get English answers, with or without the
# bot-name suffix; other chats get nothing; commands sent before the start never run; text that is
# not a command is ignored, an unknown command gets the help; a group migration gives one syslog
# entry with the new ID. R37a: no command changes the router or the modem.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup ''

# sent before the service started: confirmed on the first contact, never run
tg_push "$TG_CHAT" /status
tg_push "$TG_CHAT" /balance
pass
expect_sent 0
pass
expect_sent 0
lw_expect_eq "$(cat "$T/sms-sent" 2>/dev/null)" "" "SMS sent for a command from before the start"

tg_push "$TG_OTHER" /status
tg_push "$TG_OTHER" /help
pass
expect_sent 0

tg_push "$TG_CHAT" /help
pass
expect_sent 1
expect_last '/status – is the internet OK'
expect_last '/sms – newest SMS (/sms 10 for more)'
expect_last '/wifi – Wi-Fi name and password for guests'
expect_last '/devices – who is connected, data this month'
expect_last '/reboot – restart the router (asks to confirm)'
tg_push "$TG_CHAT" /start
tg_push "$TG_CHAT" /restart
tg_push "$TG_CHAT" '/HELP@TestBot'
pass
expect_sent 4
lw_expect_eq "$(sent_text 3)" "$(sent_text 2)" "help for an unknown command"
lw_expect_eq "$(sent_text 4)" "$(sent_text 2)" "help with the bot suffix"

# plain text in the group: nothing
tg_push "$TG_CHAT" 'hello router'
tg_push "$TG_CHAT" 'status please'
pass
expect_sent 4

# /status: the layout is tested in status.sh; here only that the command answers, with or
# without a bot name, in any case, and that it works with nothing to read
lw_net up down
sig_line -86dBm 4.6dB
tg_push "$TG_CHAT" '/Status@TestBot'
pass
expect_sent 5
expect_last '🟢 Internet works'
expect_last 'Tech: B3+B1 · RSRP -86 · SINR 4.6 · ping 50 ms · VPN 2 min'
rm -f /tmp/lw-signal.log
lw_net down down
tg_push "$TG_CHAT" /status
pass
expect_last '🔴 Internet does not work'
expect_last 'Signal: unknown'

# /sms: newest first by modem time, default 5, at most 10, at least 1
i=0
while [ "$i" -lt 12 ]; do
    sms_in "$i" +3820000000$((i % 10)) "10/$(printf %02d $((i + 1)))/26 09:00:00" "message $i"
    i=$((i + 1))
done
sms_in 12 +38200999999 '' 'no timestamp'
n=$(sent)
for arg in '' ' 3' ' 20' ' 0' ' abc'; do
    tg_push "$TG_CHAT" "/sms$arg"
done
pass
expect_sent $((n + 5))
case $(sent_text $((n + 1))) in
    '📥 Newest 5 of 13 SMS

✉️ +38200000001 · 12 Oct 09:00

message 11
────────────
✉️ +38200000000 · 11 Oct 09:00

message 10'*'message 7') ;;
    *) lw_fail "/sms: $(sent_text $((n + 1)))" ;;
esac
lw_expect_eq "$(sent_text $((n + 2)) | grep -c '^message ')" 3 "/sms 3"
lw_expect_eq "$(sent_text $((n + 3)) | grep -c '^message ')" 10 "/sms 20"
lw_expect_eq "$(sent_text $((n + 4)) | grep -c '^message ')" 1 "/sms 0"
lw_expect_eq "$(sent_text $((n + 5)) | grep -c '^message ')" 5 "/sms abc"
# 13 asked, 10 given; a message without a time counts as the oldest
tg_push "$TG_CHAT" '/sms@TestBot 13'
pass
expect_last 'Newest 10 of 13 SMS'
case $(last_text) in *'no timestamp'*) lw_fail "/sms 13 listed the oldest message" ;; esac
i=0
while [ "$i" -lt 11 ]; do
    rm -f "$T/modem/sms/$i.json"
    i=$((i + 1))
done
tg_push "$TG_CHAT" /sms
pass
expect_last 'message 11
────────────
✉️ +38200999999 · unknown

no timestamp'
rm -f "$T"/modem/sms/*.json
tg_push "$TG_CHAT" /sms
pass
expect_last '📥 No SMS in the modem.'
echo HANG >"$T/at/RECV"
tg_push "$TG_CHAT" /sms
t0=$(date +%s)
pass
[ "$(elapsed_since "$t0")" -le 6 ] || lw_fail "/sms with a hung modem took too long"
expect_last 'Could not read the SMS from the modem'
rm -f "$T/at/RECV"

# migration of the group: one entry with the new ID; the old ID keeps working until a rebuild
: >"$T/syslog"
tg_migrate "$TG_OTHER" -1009999999999
tg_migrate "$TG_CHAT" -1007777777777
pass
tg_migrate "$TG_CHAT" -1007777777777
pass
lw_expect_eq "$(wc -l <"$T/syslog")" 1 "syslog entries for the migration"
lw_expect_grep "$T/syslog" \
    "lw-notify: chat $TG_CHAT moved to -1007777777777: set TG_CHAT_ID='-1007777777777' in the"

# R37a: the commands sent no SMS (no /balance here) and changed no modem setting
lw_expect_eq "$(cat "$T/sms-sent" 2>/dev/null)" "" "SMS sent by the commands"
lw_expect_no_grep "$T/at-calls" 'AT+[A-Z]*='
echo ok
