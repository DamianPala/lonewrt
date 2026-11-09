# R26c: a silent or hung modem -> nothing deleted, an lw-sms-clean entry. R26d: DRYRUN prints the
# count and indices and changes nothing. R26e: an interrupted run leaves the full archive, and the
# next run cleans by the normal thresholds.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/modem/helpers.inc
. /fw/tests/modem/helpers.inc
modem_setup ''
A=/root/sms-archive
for i in $(seq 0 39); do
    printf '{"index":%s,"timestamp":"09/20/26 10:%02d:00","content":"m"}' "$i" "$i" >"$T/modem/sms/$i.json"
done

lw_at_override ALL SILENT
rc=0
lw-sms-clean || rc=$?
lw_expect_eq "$rc" 1 "exit code with a silent modem"
lw_expect_grep "$T/syslog" "lw-sms-clean: no message list from the modem, nothing deleted"
lw_expect_eq "$(njson "$T/modem/sms")" 40 "messages with a silent modem"
[ ! -e "$A" ] || lw_fail "archive written with a silent modem"

lw_at_override ALL HANG
: >"$T/syslog"
t0=$(date +%s)
LW_SMS_LIMIT=2 lw-sms-clean || :
lw_expect_grep "$T/syslog" "lw-sms-clean: modem not responding (AT+CPMS timed out), nothing deleted"
[ $(($(date +%s) - t0)) -le 4 ] || lw_fail "hung modem took too long"
rm -f "$T/at/ALL"
echo HANG >"$T/at/RECV"
: >"$T/syslog"
LW_SMS_LIMIT=2 lw-sms-clean || :
lw_expect_grep "$T/syslog" "no message list from the modem"
lw_expect_eq "$(njson "$T/modem/sms")" 40 "messages with a hung modem"
rm -f "$T/at/RECV"
sleep 1
no_orphans

# R26d
: >"$T/at-calls"
out=$(DRYRUN=1 MAX=0 KEEP=0 lw-sms-clean)
case $out in *"messages=40 max=0 keep=0 would delete 40: "*) ;; *) lw_fail "dry run said: $out" ;; esac
for i in $(seq 0 39); do
    case " ${out##*: } " in *" $i "*) ;; *) lw_fail "dry run misses index $i" ;; esac
done
lw_expect_eq "$(njson "$T/modem/sms")" 40 "messages after a dry run"
[ ! -e "$A" ] || lw_fail "archive written in a dry run"
lw_expect_no_grep "$T/at-calls" 'delete'
lw_expect_no_grep "$T/at-calls" 'CPMS='
out=$(DRYRUN=1 lw-sms-clean)
case $out in *"would delete 20: 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19") ;; *) lw_fail "dry run said: $out" ;; esac

# R26e: deletion hangs, the run is killed; the archive with all 40 is already there
echo HANG >"$T/at/DELETE"
LW_SMS_LIMIT=3 timeout -s KILL 2 lw-sms-clean || :
dump=$(find "$A" -name '*.json')
lw_expect_eq "$(jsonfilter -i "$dump" -e '@.msg[*].index' | wc -l)" 40 "messages in the dump"
lw_expect_eq "$(njson "$T/modem/sms")" 40 "messages after the interrupted run"
rm -f "$T/at/DELETE"
sleep 2
lw-sms-clean
lw_expect_eq "$(njson "$T/modem/sms")" 20 "messages after the next run"
lw_expect_eq "$(njson "$A")" 2 "dumps"

# R26f: a list that stays unreadable after the repair of the sender (a cut-off entry) deletes
# nothing and archives nothing; the next run, with the entry gone, cleans as usual
rm -r -f "$A" "$T/modem/sms"
mkdir -p "$T/modem/sms"
for i in $(seq 0 34); do
    printf '{"index":%s,"timestamp":"09/21/26 10:%02d:00","content":"m"}' "$i" "$i" >"$T/modem/sms/$i.json"
done
printf '{"index":90,"sender":"x"' >"$T/modem/sms/90.json"
: >"$T/syslog"
rc=0
MAX=10 KEEP=5 lw-sms-clean || rc=$?
lw_expect_eq "$rc" 1 "exit code with an unreadable list"
lw_expect_grep "$T/syslog" "lw-sms-clean: no message list from the modem, nothing deleted"
[ ! -e "$A" ] || lw_fail "archive written with an unreadable list"
lw_expect_eq "$(find "$T/modem/sms" -name '*.json' | wc -l | tr -d ' ')" 36 "messages with an unreadable list"
rm -f "$T/modem/sms/90.json"
MAX=10 KEEP=5 lw-sms-clean
lw_expect_eq "$(njson "$T/modem/sms")" 5 "messages after the entry is gone"
echo ok
