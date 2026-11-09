# R26, R26a, R26b: 30 messages or fewer -> nothing archived or deleted; above 30 -> the whole store
# archived first, the oldest deleted down to 20, a message without timestamp counted oldest, and
# the archive keeps 20 dumps.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/modem/helpers.inc
. /fw/tests/modem/helpers.inc
modem_setup ''
A=/root/sms-archive

# sms_add INDEX [TIMESTAMP]: one message in the modem model's ME store
sms_add() {
    if [ -n "${2:-}" ]; then
        printf '{"index":%s,"sender":"+38200000000","timestamp":"%s","content":"msg %s"}' "$1" "$2" "$1"
    else
        printf '{"index":%s,"sender":"+38200000000","content":"msg %s"}' "$1" "$1"
    fi >"$T/modem/sms/$1.json"
}
# day N of September 2026, so later index = newer, except where a test says otherwise
for i in $(seq 0 29); do sms_add "$i" "09/$(printf %02d $((i % 28 + 1)))/26 10:00:$(printf %02d "$i")"; done

lw-sms-clean
lw_expect_eq "$(njson "$T/modem/sms")" 30 "messages kept at 30"
[ ! -e "$A" ] || lw_fail "archive written at 30 messages"
lw_expect_grep "$T/at-calls" 'AT+CPMS="ME","ME","ME"'

# 35: indices 30-33 newest (October), 34 has no timestamp and is oldest despite its index
for i in 30 31 32 33; do sms_add "$i" "10/0$((i - 29))/26 08:00:00"; done
sms_add 34
mkdir -p "$A"
for d in $(seq 10 29); do echo '{"msg":[]}' >"$A/202601$d-000000.json"; done

lw-sms-clean
lw_expect_eq "$(njson "$T/modem/sms")" 20 "messages after cleaning"
[ ! -e "$T/modem/sms/34.json" ] || lw_fail "message without timestamp kept"
for i in 30 31 32 33; do [ -e "$T/modem/sms/$i.json" ] || lw_fail "newest message $i deleted"; done
# the 30 September messages: days 1-28 then 1-2 again for indices 28, 29; oldest 14 of them go
for i in 0 1 28 29; do [ ! -e "$T/modem/sms/$i.json" ] || lw_fail "old message $i kept"; done
lw_expect_eq "$(njson "$A")" 20 "archive dumps"
[ ! -e "$A/20260110-000000.json" ] || lw_fail "oldest dump kept"
new=$(find "$A" -name '*.json' ! -name '202601*')
[ -n "$new" ] || lw_fail "no new dump"
lw_expect_eq "$(jsonfilter -i "$new" -e '@.msg[*].index' | wc -l)" 35 "messages in the dump"
case $(basename "$new") in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].json) ;;
    *) lw_fail "dump name $new" ;;
esac
lw_expect_grep "$T/syslog" "lw-sms-clean: deleted 15 of 35 messages (0 failed)"
lw_expect_eq "$(grep -cv '^/dev/ttyUSB2 ' "$T/at-calls" || :)" 0 "modem calls off /dev/ttyUSB2"

# R26f: a sender with a quote or a backslash makes the raw list invalid JSON (sms_tool does not
# escape it); the cleaning repairs the field like lw-notify (R34h), deletes by the repaired list, and
# the dump holds the repaired list, which is valid JSON
rm -r -f "$A" "$T/modem/sms"
mkdir -p "$T/modem/sms"
for i in $(seq 0 34); do sms_add "$i" "10/$(printf %02d $((i % 28 + 1)))/26 08:00:00"; done
printf '{"index":3,"sender":"%s","timestamp":"10/04/26 08:00:00","content":"quote"}' 'AB"CD' >"$T/modem/sms/3.json"
printf '{"index":4,"sender":"%s","timestamp":"10/05/26 08:00:00","content":"backslash"}' 'AB\CD' >"$T/modem/sms/4.json"
: >"$T/syslog"
lw-sms-clean
lw_expect_eq "$(njson "$T/modem/sms")" 20 "messages after cleaning a store with unescaped senders"
lw_expect_grep "$T/syslog" "lw-sms-clean: deleted 15 of 35 messages (0 failed)"
dump=$(find "$A" -name '*.json')
lw_expect_eq "$(jsonfilter -i "$dump" -e '@.msg[*].index' | wc -l)" 35 "messages in the repaired dump"
lw_expect_eq "$(jsonfilter -i "$dump" -e '@.msg[@.index=3].sender')" 'AB"CD' "quote sender in the dump"
lw_expect_eq "$(jsonfilter -i "$dump" -e '@.msg[@.index=4].sender')" 'AB\CD' "backslash sender in the dump"
# R34i: the dump holds SMS texts, so only root reads it
lw_expect_eq "$(find "$A" -perm /077)" "" "archive open to group or others"
echo ok
