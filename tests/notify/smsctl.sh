# R46, R46a: SMS control. A command from a number in lonewrt.notify.sms_admins gets one reply SMS to the
# sender's number; the number filter (digits only), the letter case and the spaces around the word,
# other text from an admin gets HELP, other numbers get nothing, a failed send is logged once and not
# repeated, Telegram unreachable changes nothing, every SMS still reaches the chat (R34), and a
# reply text is one ASCII SMS. All numbers here are fake.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup 7.50
HELP='Home router commands: status, reboot'
ADMIN=+48000000001
admins_set "$ADMIN,0038200000002"
lw_net up down
sig_line -86dBm 4.6dB
# the balance reply of today 11:05 is in the store from the start; the first pass only records it
sms_in 0 1466 '11/07/26 11:05:00' 'Imate: 0.31 do 05.01.; '
passes 2
lw_uptime_set 1140
expect_sent 0

# --- the R46a OK text, from the number as the modem prints it (digits, no plus)
sms_cmd 48000000001 status
lw_expect_eq "$(sms_out)" 1 "replies to STATUS"
lw_expect_eq "$(sms_to 1)" "${ADMIN#+}" "reply goes to the sender, without a plus"
lw_expect_eq "$(sms_body 1)" "Home router: internet OK (4G+), signal fair. On since 7 Nov 11:01. Balance 0.31 EUR (7 Nov)." \
    "STATUS text"
# R46: the command is on the chat as an ordinary SMS
expect_sent 1
expect_last 'status'
expect_last '✉️ +48000000001'

# --- case, spaces around the word, the other spelling of the number
sms_cmd +48000000001 '  StAtUs  '
lw_expect_eq "$(sms_out)" 2 "replies to ' StAtUs '"
lw_expect_eq "$(sms_body 2 | cut -c1-32)" "Home router: internet OK (4G+), " "text for ' StAtUs '"
sms_cmd 38200000002 'HELP'
lw_expect_eq "$(sms_to 3)" 38200000002 "second admin, number written with 00 in the list"
lw_expect_eq "$(sms_body 3)" "$HELP" "HELP text"
sms_cmd 0048000000001 'status\n'
lw_expect_eq "$(sms_out)" 4 "replies to a sender written with 00 and a text with a line break"
lw_expect_eq "$(sms_to 4)" "${ADMIN#+}" "number with 00"

# --- other text from an admin gets HELP
sms_cmd +48000000001 'restart please'
lw_expect_eq "$(sms_body 5)" "$HELP" "text other than a command"
sms_cmd +48000000001 'STATUS now'
lw_expect_eq "$(sms_body 6)" "$HELP" "a command word with more words"
sms_cmd +48000000001 ''
lw_expect_eq "$(sms_body 7)" "$HELP" "empty text"
lw_expect_eq "$(reboots_n)" 0 "restarts so far"

# --- numbers off the list get nothing, and neither does a short code or a name
sms_cmd +48000000099 'STATUS'
sms_cmd 4800000001 'STATUS'
sms_cmd 1466 'STATUS'
sms_cmd Telekom 'STATUS'
sms_cmd '' 'REBOOT'
lw_expect_eq "$(sms_out)" 7 "replies to numbers off the list"
lw_expect_eq "$(reboots_n)" 0 "restarts for numbers off the list"
# each of them is still an ordinary SMS on the chat
expect_last 'REBOOT'

# --- our own reply text coming back (two routers) is not a command
sms_cmd +48000000001 "$HELP"
lw_expect_eq "$(sms_out)" 7 "reply to a text that looks like our own reply"

# --- the list: entries of the wrong length are dropped, so a short code cannot become an admin
admins_set '1466,123,+48000000001234567890'
sms_cmd 1466 'STATUS'
sms_cmd 123 'STATUS'
lw_expect_eq "$(sms_out)" 7 "replies to short list entries"
admins_set ''
sms_cmd +48000000001 'STATUS'
lw_expect_eq "$(sms_out)" 7 "replies with no admins"
admins_set "$ADMIN"
sms_cmd +48000000001 'STATUS'
lw_expect_eq "$(sms_out)" 8 "reply with the list back"

# --- a failed send: one syslog entry, no second try, the chat copy goes out all the same
# (a day later, so the allowance of the replies above is free again; the limit has its own test)
wall_add 90000
: >"$T/syslog"
n=$(sent)
echo FAIL >"$T/at/SEND"
sms_cmd +48000000001 'STATUS'
passes 4
lw_expect_eq "$(sms_out)" 8 "reply when the send fails"
lw_expect_eq "$(grep -c 'lw-notify: SMS control: reply not sent' "$T/syslog")" 1 "failed-send entries"
lw_expect_grep "$T/syslog" 'reply not sent (exit 1'
lw_expect_eq "$(sent)" $((n + 1)) "chat copy of the command"
echo NOTSENT >"$T/at/SEND"
: >"$T/syslog"
sms_cmd +48000000001 'STATUS'
passes 3
lw_expect_eq "$(sms_out)" 8 "reply when the tool reports 'not sent' with exit 0"
lw_expect_eq "$(grep -c 'lw-notify: SMS control: reply not sent' "$T/syslog")" 1 "not-sent entries"
lw_expect_grep "$T/syslog" 'sms not sent, code: 330'
rm -f "$T/at/SEND"
# a hung modem ends within the send limit and leaves no process
echo HANG >"$T/at/SEND"
: >"$T/syslog"
t0=$(date +%s)
sms_cmd +48000000001 'STATUS'
[ "$(elapsed_since "$t0")" -le 8 ] || lw_fail "a hung send took $(elapsed_since "$t0") s"
lw_expect_grep "$T/syslog" 'reply not sent (exit 124'
rm -f "$T/at/SEND"
sleep 1
no_orphans

# --- Telegram unreachable: the reply goes all the same, the SMS waits for the chat
echo down >"$G/net"
wall_add 90000
n=$(sent)
sms_cmd +48000000001 'HELP'
lw_expect_eq "$(sms_out)" 9 "reply while Telegram is unreachable"
lw_expect_eq "$(sms_body 9)" "$HELP" "text while Telegram is unreachable"
lw_expect_eq "$(sent)" "$n" "chat messages while Telegram is down"
echo up >"$G/net"
passes 2
lw_expect_eq "$(sent)" $((n + 1)) "the command reaches the chat when Telegram is back"
expect_last 'HELP'

# --- a list entry written without a country code gets the reply in that form (docs/profile.md asks for
# the international form, the router cannot add a country code)
admins_set "$ADMIN,067000001"
sms_cmd 067000001 'HELP'
lw_expect_eq "$(sms_to 10)" 067000001 "reply to a national list entry, no plus"
# --- no reply ever goes out with a plus
lw_expect_eq "$(cut -d' ' -f1 "$T/sms-sent" | grep -c '^+')" 0 "numbers with a plus passed to sms_tool"

# --- R46a: every reply is ASCII and at most 160 characters
for i in $(seq 1 "$(sms_out)"); do
    [ "$(sms_body "$i" | wc -c)" -le 161 ] || lw_fail "reply $i longer than 160: $(sms_body "$i")"
    [ "$(sms_body "$i" | tr -d '\012\040-\176' | wc -c)" = 0 ] || lw_fail "reply $i is not ASCII"
done
echo ok
