# State, log and snapshot format (R20, R21c, R21d, R21e, R29b): key=value state with the R21d keys,
# written atomically only when a field other than uptime changes; each wwan-recover entry ends with
# the R21e fields; a new failure starts a new snapshot (old one to .old) whose entries have reason,
# cycle, uptime and the last 12 lines of the signal log.
# shellcheck source=tests/ladder/ladder.inc
. /fw/tests/ladder/ladder.inc

lw_net up down
runs 3
[ ! -e "$STATE" ] || lw_fail "state written while online"
[ ! -s "$T/syslog" ] || lw_fail "log entries while online: $(cat "$T/syslog")"

for i in $(seq 1 20); do echo "2026-11-06_12:$i:03 zsnt=6 line-$i." >>/tmp/lw-signal.log; done
echo "previous failure" >"$SNAP"
lw_net down down
lw_dns down down
runs 1
lw_expect_eq "$(cat "$STATE")" "cycles=1
reboots=0
class=hang
passive=0
uptime=1900" "state after the first failure cycle"
lw_expect_eq "$(cat "$SNAP.old")" "previous failure" "old snapshot"
lw_expect_eq "$(grep -c '^===' "$SNAP")" 1 "entries in the new snapshot"
lw_expect_grep "$SNAP" "^=== failure start cycle=1 reboots=0 class=hang mode=lte uptime=1900 date="
lw_expect_grep "$SNAP" "line-9\.$"
lw_expect_grep "$SNAP" "line-20\.$"
lw_expect_no_grep "$SNAP" "line-8\."
lw_expect_grep "$SNAP" "AT+CPIN? -> +CPIN: READY"

runs 1
lw_expect_eq "$(state_get uptime)" 2200 "uptime written with the new cycle"
lw_expect_eq "$(state_get cycles)" 2 "cycles"
lw_expect_eq "$(find /etc -name 'wwan-recover.state.tmp*' | wc -l)" 0 "temp files of the atomic write"

# A run that ends at the lock of a live run changes nothing, so the state is not rewritten.
before=$(ls -i "$STATE"; md5sum <"$STATE")
sh -c 'sleep 30; true' wwan-recover &
fake=$!
ln -s "$fake::$(cut -d. -f1 "$T/uptime")" /tmp/wwan-recover.lock
lw_uptime_add 300
"$WR" >>"$T/out" 2>&1
lw_expect_eq "$(ls -i "$STATE"; md5sum <"$STATE")" "$before" "state after a run that only waited"
lw_expect_grep "$T/syslog" "previous run (pid $fake) still active, exiting cycle=2 "
kill "$fake"
rm -f /tmp/wwan-recover.lock

lw_net up down
runs 1
[ ! -e "$STATE" ] || lw_fail "state left after the failure ended"
lw_expect_grep "$T/syslog" "wwan-recover: online on LTE, failure over after 2 cycles and 0 reboots cycle=2 reboots=0 class=hang mode=lte uptime=2800"
check_format
echo ok
