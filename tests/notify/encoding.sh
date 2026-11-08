# R34e: sms_tool prints U+0080..U+00FF as one raw byte (Latin-1). Telegram takes UTF-8 only and
# answers HTTP 400 otherwise (the fake bot rejects invalid UTF-8 like that), so every text that
# goes out must be valid UTF-8: a byte outside a valid sequence leaves as the UTF-8 of that code
# point, valid UTF-8 stays byte for byte. Covers the SPEC scenario, the encoder on its own, a file
# already in the queue and the bot's own replies.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup ''
# shellcheck source=src/files/usr/lib/lw/common.sh
. /usr/lib/lw/common.sh
# shellcheck source=src/files/usr/lib/lw/notify.sh
. /usr/lib/lw/notify.sh
echo utf8 >"$G/reject400"

hex_of() { hexdump -v -e '/1 "%02X"' "$1"; }
# sent_has N HEX: the Nth message contains the bytes HEX
sent_has() {
    case $(hex_of "$G/sent/$1.text") in
        *"$2"*) ;;
        *) lw_fail "message $1 lacks bytes $2: $(hex_of "$G/sent/$1.text")" ;;
    esac
}

# enc FORMAT EXPECTED [ascii]: nt_urlencode of printf FORMAT (octal escapes) is EXPECTED
enc() {
    # shellcheck disable=SC2059  # the format is the test input
    _in=$(printf "$1")
    lw_expect_eq "$(nt_urlencode "$_in" "${3:-}")" "$2" "encoding of $1 ${3:-}"
}

# Latin-1 bytes become their code points
enc 'm\363j' 'm%C3%B3j'
enc '\351\374\344' '%C3%A9%C3%BC%C3%A4'
enc '\200\240\277' '%C2%80%C2%A0%C2%BF'
enc '\300\377' '%C3%80%C3%BF'
# valid UTF-8 stays: Polish letters, euro, emoji, and the edges of every length
enc 'm\303\263j \305\233 \304\207 \342\202\254 \360\237\230\200' \
    'm%C3%B3j%20%C5%9B%20%C4%87%20%E2%82%AC%20%F0%9F%98%80'
enc '\302\200\337\277\340\240\200\355\237\277\357\277\277\360\220\200\200\364\217\277\277' \
    '%C2%80%DF%BF%E0%A0%80%ED%9F%BF%EF%BF%BF%F0%90%80%80%F4%8F%BF%BF'
enc 'abc-._~ 09' 'abc-._~%2009'
enc '' ''
# a lone lead byte at the end, before ASCII, and a cut-off sequence
enc 'a\303' 'a%C3%83'
enc '\303x' '%C3%83x'
enc 'a\342\202' 'a%C3%A2%C2%82'
enc '\360\237\230' '%C3%B0%C2%9F%C2%98'
# overlong forms, surrogates, above U+10FFFF, bytes that never start a sequence
enc '\300\200' '%C3%80%C2%80'
enc '\301\277' '%C3%81%C2%BF'
enc '\340\200\200' '%C3%A0%C2%80%C2%80'
enc '\360\200\200\200' '%C3%B0%C2%80%C2%80%C2%80'
enc '\355\240\200' '%C3%AD%C2%A0%C2%80'
enc '\364\220\200\200' '%C3%B4%C2%90%C2%80%C2%80'
enc '\365\200\200\200' '%C3%B5%C2%80%C2%80%C2%80'
# Latin-1 next to valid UTF-8 (o-acute then s-acute; s-acute then a stray continuation)
enc '\363\305\233' '%C3%B3%C5%9B'
enc '\305\233\233' '%C5%9B%C2%9B'
# ASCII mode (R34f): one ? per character, valid or not
enc 'm\363j' 'm?j' ascii
enc 'm\303\263j' 'm?j' ascii
enc 'a\360\237\230\200b' 'a?b' ascii
enc 'a\342\202' 'a??' ascii
enc 'ab c' 'ab%20c' ascii

# R34e scenario: a Latin-1 byte in an SMS, then a second SMS; both arrive, in order, with o-acute
passes 3
sms_in 0 +38200000001 '11/07/26 12:00:00' "m$(printf '\363')j kolejny testowy SMS"
sms_in 1 +38200000002 '11/07/26 12:00:05' 'second one'
passes 2
expect_sent 2
sent_has 1 '6DC3B36A206B6F6C656A6E79' # "m" C3 B3 "j kolejny"
lw_expect_eq "$(sent_text 2 | tail -n 1)" 'second one' "second message"
lw_expect_eq "$(rejected_n)" 0 "rejections by the fake bot"
[ -z "$(find /etc/lw-notify/queue -type f)" ] || lw_fail "queue not empty"
lw_expect_eq "$(cat "$T/syslog")" "" "syslog after forwarding Latin-1"
# the SMS key is made from what the modem sent, so a reboot does not bring it back
lw_reboot_sim
passes 4
expect_sent 2

# valid UTF-8 untouched all the way: raw bytes, and JSON escapes (what sms_tool prints for U+0100+)
sms_in 2 +38200000003 '11/07/26 12:10:00' "$(printf 'm\303\263j \305\233')"
sms_in 3 +38200000004 '11/07/26 12:10:05' '\u015b \ud83d\ude00 \u00e9'
passes 2
expect_sent 4
sent_has 3 '6DC3B36A20C59B'
sent_has 4 'C59B20F09F988020C3A9' # s-acute, emoji (surrogate pair), e-acute
lw_expect_eq "$(rejected_n)" 0 "rejections after valid UTF-8"

# a file that was in the queue before this fix (raw byte on flash) goes out right
mkdir -p /etc/lw-notify/queue
printf 'old queue entry m\363j\n' >/etc/lw-notify/queue/000099-oldkey
pass
expect_sent 5
sent_has 5 '6DC3B36A'
[ -z "$(find /etc/lw-notify/queue -type f)" ] || lw_fail "old entry stayed in the queue"

# the bot's own replies: /sms lists a Latin-1 message, a command reply with it is valid UTF-8
tg_push "$TG_CHAT" /sms
pass
expect_sent 6
sent_has 6 '6DC3B36A'
lw_expect_eq "$(rejected_n)" 0 "rejections for the /sms reply"
lw_expect_eq "$(cat "$T/syslog")" "" "syslog at the end"
no_orphans
echo ok
