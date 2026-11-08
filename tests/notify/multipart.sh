# R34g, D67: a long SMS arrives in parts that share sender and reference, in any order. The chat gets
# one message with the parts joined in the order of "part" and no separator once all are there, or
# what is there with "(part n of t missing)" 10 minutes after the first part was seen. /sms shows
# and counts the joined messages, no SMS command comes from parts, nothing is forwarded twice (also
# across a restart while waiting), a Latin-1 byte is repaired in each part before the join, and the
# poll stays cheap while a part is missing.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup ''
echo utf8 >"$G/reject400"
S=+38200000001
passes 3
expect_sent 0

hex_of() { hexdump -v -e '/1 "%02X"' "$1"; }
# body N: the text of message N without its two header lines
body() { sent_text "$1" | tail -n +3; }
# later SECONDS: the clocks of the service move on
later() { lw_uptime_add "$1"; wall_add "$1"; }
# restart: the router restarts and ntpd syncs the clock again
restart() { reboot_sim ""; ntp_on; }

# --- two parts, the second one first, and the parts' indexes in the other order
sms_part 21 $S '11/07/26 11:30:00' 160 2 2 ' and the second half.'
passes 2
expect_sent 0
[ -z "$(find /etc/lw-notify/queue -type f 2>/dev/null)" ] || lw_fail "a lone part was queued"
sms_part 20 $S '11/07/26 11:29:58' 160 1 2 'This is the first half'
passes 2
expect_sent 1
lw_expect_eq "$(sent_text 1)" "✉️ +38200000001 · Today 11:29

This is the first half and the second half." "two parts joined, no separator"
passes 3
expect_sent 1

# the same parts are in the store after a restart: nothing comes again
restart
passes 5
expect_sent 1
lw_expect_eq "$(rejected_n)" 0 "rejections by the fake bot"

# --- three parts, the middle one never comes: nothing before 10 minutes, then what there is
sms_part 31 $S '11/07/26 11:40:00' 161 3 3 'Part three.'
sms_part 30 $S '11/07/26 11:40:00' 161 1 3 'Part one. '
passes 2
expect_sent 1
: >"$T/at-calls"
later 300
passes 3
expect_sent 1
lw_expect_no_grep "$T/at-calls" recv
# the wait counts from the first sight of the first part, so it is up some 600 s after it
later 290
: >"$T/at-calls"
passes 3
expect_sent 1
lw_expect_no_grep "$T/at-calls" recv
later 20
passes 4
expect_sent 2
lw_expect_eq "$(sent_text 2)" "✉️ +38200000001 · Today 11:40

Part one. Part three.
(part 2 of 3 missing)" "a group forwarded with a part missing"
passes 4
expect_sent 2
restart
passes 5
expect_sent 2
# the part that comes late is a message of its own, with what is missing around it
sms_part 32 $S '11/07/26 12:00:00' 161 2 3 'Part two, late.'
passes 2
expect_sent 2
later 700
passes 4
expect_sent 3
lw_expect_eq "$(body 3)" "Part two, late.
(part 1 of 3 missing)
(part 3 of 3 missing)" "the late part"
lw_expect_eq "$(grep -c . "$T/syslog")" 0 "syslog"

# --- a restart while waiting: the parts are still unhandled, and the message comes once
sms_part 40 $S '11/07/26 12:10:00' 162 1 2 'Wait for it, '
passes 2
expect_sent 3
restart
passes 4
expect_sent 3
sms_part 41 $S '11/07/26 12:10:02' 162 2 2 'then it came.'
passes 2
expect_sent 4
lw_expect_eq "$(body 4)" "Wait for it, then it came." "joined after a restart"
restart
passes 5
expect_sent 4

# --- two long messages of one sender with different references, parts mixed; the same reference
# from another sender is another message too
sms_part 50 $S '11/07/26 12:20:00' 170 1 2 'Alpha one, '
sms_part 51 $S '11/07/26 12:20:00' 171 1 2 'Beta one, '
sms_part 52 +38200000002 '11/07/26 12:20:00' 170 1 2 'Gamma one, '
sms_part 53 $S '11/07/26 12:20:01' 171 2 2 'beta two.'
sms_part 54 $S '11/07/26 12:20:01' 170 2 2 'alpha two.'
passes 2
expect_sent 6
lw_expect_eq "$(body 5)" "Alpha one, alpha two." "reference 170"
lw_expect_eq "$(body 6)" "Beta one, beta two." "reference 171"
# the other sender's part 1 still waits for its part 2
sms_part 55 +38200000002 '11/07/26 12:20:02' 170 2 2 'gamma two.'
passes 2
expect_sent 7
lw_expect_eq "$(sent_text 7 | head -n 1)" "✉️ +38200000002 · Today 12:20" "the other sender"
lw_expect_eq "$(body 7)" "Gamma one, gamma two." "same reference, other sender"

# --- a Latin-1 byte: repaired in its part before the join. Part 1 ends with the byte C3 and part 2
# starts with A9, which joined first would read as the one character U+00E9; each part is Latin-1
# on its own, so the chat gets U+00C3 and U+00A9
sms_part 60 $S '11/07/26 12:30:00' 180 1 2 "caf$(printf '\303')"
sms_part 61 $S '11/07/26 12:30:00' 180 2 2 "$(printf '\251') m$(printf '\363')j"
passes 2
expect_sent 8
case $(hex_of "$G/sent/8.text") in
    *636166C383C2A9206DC3B36A) ;;
    *) lw_fail "Latin-1 parts: $(hex_of "$G/sent/8.text")" ;;
esac
lw_expect_eq "$(rejected_n)" 0 "rejections after Latin-1 parts"
# a part of its own with a stray byte, valid UTF-8 in the other part stays
sms_part 62 $S '11/07/26 12:31:00' 181 1 2 "$(printf 'm\303\263j ')"
sms_part 63 $S '11/07/26 12:31:00' 181 2 2 "n$(printf '\351')"
passes 2
expect_sent 9
case $(hex_of "$G/sent/9.text") in
    *6DC3B36A206EC3A9) ;;
    *) lw_fail "mixed parts: $(hex_of "$G/sent/9.text")" ;;
esac
lw_expect_eq "$(rejected_n)" 0 "rejections after mixed parts"

# --- /sms shows and counts the joined messages: a single SMS, the 2-part message of 12:40 and a
# 3-part message with the last part missing, newest first
for f in "$T"/modem/sms/*.json; do rm -f "$f"; done
sms_in 70 +38200000009 '11/07/26 12:35:00' 'a plain one'
sms_part 71 $S '11/07/26 12:40:00' 190 2 2 'two of two'
sms_part 72 $S '11/07/26 12:40:00' 190 1 2 'one of two, '
sms_part 73 $S '11/07/26 12:45:00' 191 1 3 'x1 '
sms_part 74 $S '11/07/26 12:45:00' 191 2 3 'x2'
n=$(sent)
tg_push "$TG_CHAT" /sms
pass
lw_expect_eq "$(sent)" $((n + 1)) "replies to /sms"
case $(last_text) in
    '📥 Newest 3 of 3 SMS
'*) ;;
    *) lw_fail "/sms count: $(last_text)" ;;
esac
lw_expect_eq "$(last_text)" "📥 Newest 3 of 3 SMS

✉️ +38200000001 · Today 12:45

x1 x2
(part 3 of 3 missing)
────────────
✉️ +38200000001 · Today 12:40

one of two, two of two
────────────
✉️ +38200000009 · Today 12:35

a plain one" "/sms with joined messages"
tg_push "$TG_CHAT" '/sms 2'
pass
case $(last_text) in
    '📥 Newest 2 of 3 SMS
'*'x1 x2
(part 3 of 3 missing)'*'one of two, two of two') ;;
    *) lw_fail "/sms 2: $(last_text)" ;;
esac
# an empty store
for f in "$T"/modem/sms/*.json; do rm -f "$f"; done
tg_push "$TG_CHAT" /sms
pass
expect_last 'No SMS in the modem'

# --- no SMS command comes from a long message, though it reads STATUS when joined
ADMIN_DIGITS=48000000001
admins_set "+$ADMIN_DIGITS"
passes 2
n=$(sms_out)
sms_part 80 $ADMIN_DIGITS '11/07/26 13:00:00' 200 1 2 'STA'
sms_part 81 $ADMIN_DIGITS '11/07/26 13:00:00' 200 2 2 'TUS'
passes 2
lw_expect_eq "$(sms_out)" "$n" "SMS sent for a command in parts"
lw_expect_eq "$(last_text | tail -n 1)" "STATUS" "the parts still reach the chat"
sms_part 82 $ADMIN_DIGITS '11/07/26 13:01:00' 201 1 2 'REBOO'
sms_part 83 $ADMIN_DIGITS '11/07/26 13:01:00' 201 2 2 'T'
passes 4
lw_expect_eq "$(reboots_n)" 0 "restarts for a REBOOT in parts"
lw_expect_eq "$(sms_out)" "$n" "SMS sent for a REBOOT in parts"
# a single-part command from the same number still works
sms_cmd $ADMIN_DIGITS status
lw_expect_eq "$(sms_out)" $((n + 1)) "a plain command next to the long ones"

# --- a part with fields that make no sense is an ordinary message
sms_in 90 +38200000004 '11/07/26 13:10:00' 'plain'
printf '{"index":91,"sender":"+38200000004","timestamp":"11/07/26 13:11:00","reference":5,"part":3,"total":2,"content":"part past the total"}' \
    >"$T/modem/sms/91.json"
printf '{"index":92,"sender":"+38200000004","timestamp":"11/07/26 13:12:00","reference":5,"part":1,"total":1,"content":"one of one"}' \
    >"$T/modem/sms/92.json"
n=$(sent)
passes 3
lw_expect_eq "$(sent)" $((n + 3)) "odd fields: forwarded as they are"
expect_last 'one of one'

# --- SMS control alone (no chat): parts are handled at once, nothing waits, nothing is queued
uci -q delete lonewrt.notify.token
uci -q delete lonewrt.notify.chat
uci -q commit lonewrt
rm -rf /tmp/lw-notify /etc/lw-notify/seen
passes 3
sms_part 100 $S '11/07/26 14:00:00' 210 1 2 'only half'
passes 2
[ ! -e /etc/lw-notify/queue ] || [ -z "$(find /etc/lw-notify/queue -type f)" ] || lw_fail "queued without a chat"
grep -qF "$(printf '%s|%s|%s|%s' 100 $S '11/07/26 14:00:00' 'only half' | md5sum | cut -c1-16)" \
    /etc/lw-notify/seen || lw_fail "a part without a chat is not on the seen list"
[ ! -e /tmp/lw-notify/mp_due ] || lw_fail "a wait started without a chat"
no_orphans
echo ok
