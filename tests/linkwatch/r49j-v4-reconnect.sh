# R49j, D218: in a dual-stack session whose IPv4 is lost while IPv6 works, the session watcher
# (`lw-linkwatch run`, the one executor) reconnects with `ifup wwan` a bounded number of times: the 1st
# when IPv4 has been lost 10 min, the 2nd 30 min after the 1st, the 3rd 60 min after the 2nd, then none
# until IPv4 has worked for 60 min without a break (or a boot). One signal: the watcher's own lost IPv4
# call that it could not restore (R49d, "IPv6 kept, no ifup"). The chain is kept in the process's memory
# and written to /var/run/lw-linkwatch/v4chain (`N LAST`) only when it changes; the loss time belongs to
# the session (the marker of the escalation), the count and the gaps to the chain. `once` reports and
# never reconnects.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc
SID=17/3203210528
CHAIN=/var/run/lw-linkwatch/v4chain
MARK=/var/run/lw-family/negotiating
ifups() { grep -c '^ifup wwan$' "$EVENTS" || true; }
reconnects() { lk_lines | grep -c 'while IPv6 works, ifup wwan, reconnect' || true; }
exhausted() { lk_lines | grep -c ' IPv4 stays lost, no more reconnects until it works for 60 min or a restart$' || true; }
dues() { lk_lines | grep -c 'is due; only the service makes it' || true; }
chain() { cat "$CHAIN" 2>/dev/null || echo -; }
at() { lw_uptime_set "$1"; }
last_line() { lk_lines | tail -n "${1:-1}" | head -n 1; }

# the changes of the world that an item of pass_at can make between two passes
HEAL="echo up >$T/uqmi/session; echo registered >$T/uqmi/reg; echo $OLD_ADDR >$T/uqmi/addr; echo $OLD_ADDR >$T/addr/wwan0"
LOSE="echo down >$T/uqmi/session"
WWAN_DOWN="sed -i 's/\"up\":true/\"up\":false/' $T/ifstatus/wwan.json"
WWAN_UP="sed -i 's/\"up\":false/\"up\":true/' $T/ifstatus/wwan.json"
OTHER_SESSION="sed -i 's/\"cid_4\":\"17\"/\"cid_4\":\"19\"/' $T/ifstatus/wwan.json"

# pass_at SECOND...: the service (`lw-linkwatch run`) makes a pass at each second, in order, the first
# one at once. An item `SECOND|COMMAND` runs COMMAND (a change of the world) after the clock is set to
# SECOND and before the pass. The stand-in sleep calls the hook after the nap of 7 s between two
# passes (the naps inside an incident are 1 and 2 s), which sets the clock; before that it writes
# "SECOND|IFUPS|CHAIN" of the pass that just ended to $T/snap, and after the last pass this function
# does. snap_ifups SECOND and snap_chain SECOND read what was there after the pass at SECOND.
pass_at() {
    _first=$1
    shift
    at "$_first"
    : >"$T/timeline"
    : >"$T/snap"
    echo "$_first" >"$T/cur"
    for _s in "$@"; do echo "$_s" >>"$T/timeline"; done
    cat >"$T/on-sleep" <<'HOOK'
#!/bin/sh
T=/lwtest
[ "$(tail -n 1 "$T/sleeps")" = "sleep 7" ] || exit 0
line=$(head -n 1 "$T/timeline") || exit 0
[ -n "$line" ] || exit 0
sed -i 1d "$T/timeline"
printf '%s|%s|%s\n' "$(cat "$T/cur")" "$(grep -c '^ifup wwan$' "$T/events" || true)" \
    "$(cat /var/run/lw-linkwatch/v4chain 2>/dev/null || echo -)" >>"$T/snap"
sec=${line%%|*}
echo "$sec" >"$T/cur"
printf '%s.00 %s.00\n' "$sec" "$sec" >"${LW_UPTIME_FILE:-$T/uptime}"
case $line in *'|'*) sh -c "${line#*|}" ;; esac
HOOK
    chmod +x "$T/on-sleep"
    LW_LINKWATCH_PERIOD=7 LW_LINKWATCH_PASSES=$(($# + 1)) lw-linkwatch run
    printf '%s|%s|%s\n' "$(cat "$T/cur")" "$(ifups)" "$(chain)" >>"$T/snap"
    rm -f "$T/on-sleep"
}
snap_ifups() { awk -F'|' -v s="$1" '$1 == s { v = $2 } END { print v }' "$T/snap"; }
snap_chain() { awk -F'|' -v s="$1" '$1 == s { v = $3 } END { print v }' "$T/snap"; }
# seqs FROM STEP TO: the seconds of a pass every STEP seconds
seqs() { seq "$1" "$2" "$3" | tr '\n' ' '; }

# a dual-stack session whose IPv4 start never works and whose IPv6 answers (the clock is at 1000 s)
failing() {
    lk_setup
    lk_dual
    lk_lost
    echo '"Call failed"' >"$T/uqmi/q-start"
    lk_v6result $SID - 1005 answer
}
# a dual-stack session that stays connected
dual_ok() {
    lk_setup
    lk_dual
}
expect_line() {
    last_line "$1" | grep -qE " lw-linkwatch: $2\$" || lw_fail "$3: $(last_line "$1")"
}

# the schedule: 10 min, then 30 min after the 1st, then 60 min after the 2nd, then none
failing
# shellcheck disable=SC2046  # a list of seconds
pass_at 1000 1599 1600 1601 3399 3400 3401 6999 7000 7001 $((7000 + 3600)) $((7000 + 18000)) $((7000 + 86400))
lw_expect_eq "$(snap_ifups 1000)" 0 "ifup wwan events after the incident"
lw_expect_eq "$(snap_chain 1000)" - "chain after the incident (written when it changes)"
lw_expect_eq "$(snap_ifups 1599)" 0 "ifup wwan events 599 s into the loss"
lw_expect_eq "$(snap_ifups 1600)" 1 "ifup wwan events 600 s into the loss"
lw_expect_eq "$(snap_chain 1600)" "1 1600" "chain after the 1st reconnect"
lw_expect_eq "$(snap_ifups 1601)" 1 "ifup wwan events on the next pass"
lw_expect_eq "$(snap_ifups 3399)" 1 "ifup wwan events 1799 s after the 1st"
lw_expect_eq "$(snap_ifups 3400)" 2 "ifup wwan events 1800 s after the 1st"
lw_expect_eq "$(snap_chain 3400)" "2 3400" "chain after the 2nd reconnect"
lw_expect_eq "$(snap_ifups 6999)" 2 "ifup wwan events 3599 s after the 2nd"
lw_expect_eq "$(snap_ifups 7000)" 3 "ifup wwan events 3600 s after the 2nd"
lw_expect_eq "$(snap_chain 7000)" "3 7000" "chain after the 3rd reconnect"
lw_expect_eq "$(ifups)" 3 "ifup wwan events after the third reconnect (the bound)"
lw_expect_eq "$(reconnects)" 3 "reconnect lines"
lw_expect_eq "$(exhausted)" 1 "lines about the used-up reconnects"
lw_expect_eq "$(chain)" "3 7000" "reconnects in the chain"
lw_expect_eq "$(lk_info)" 5 "watcher syslog lines: the incident, 3 reconnects, the used-up line"
# the used-up line comes with the 3rd reconnect, not after another signal of the loss
expect_line 2 "IPv4 lost for 100 min while IPv6 works, ifup wwan, reconnect 3 of 3" "line of the 3rd reconnect"
expect_line 1 "IPv4 stays lost, no more reconnects until it works for 60 min or a restart" "line of the used-up reconnects"
lw_expect_eq "$(ls -ld /var/run/lw-linkwatch | cut -c1-10)" drwx------ "mode of the state directory"
lw_expect_eq "$(cat "$MARK")" 7030 "negotiation mark of the latest reconnect (R14f)"
[ ! -e /var/run/lw-linkwatch/v4lock ] || lw_fail "a lock file of the chain"

# the first line: lost for 10 min, reconnect 1 of 3
failing
pass_at 1000 1600
expect_line 1 "IPv4 lost for 10 min while IPv6 works, ifup wwan, reconnect 1 of 3" "line of the 1st reconnect"
# the start the reconnect begins is marked (R14f), so that watchcat's own restart waits for it
lw_expect_eq "$(cat "$MARK")" 1630 "deadline of the negotiation mark of the reconnect"
# and the ladder of wwan-recover is kept off wwan by the reservation: a fixed deadline 60 s ahead, in the
# watcher's own directory (R14h)
lw_expect_eq "$(cat /var/run/lw-linkwatch/v4reserve)" 1660 "deadline of the reservation of the reconnect"

# the max is a constant with a test override: 1 allows one, and its line comes with it
failing
export LW_LINKWATCH_V4_MAX=1
pass_at 1000 1600 100000
unset LW_LINKWATCH_V4_MAX
lw_expect_eq "$(exhausted)" 1 "line about the used-up reconnect with a maximum of 1"
lw_expect_eq "$(ifups)" 1 "ifup wwan events with a maximum of 1"

# a respawn of the service: the count and the latest second come back from the file, the loss time from
# the marker of the session (R49d), so the chain goes on with the 2nd reconnect at its gap
failing
pass_at 1000 1600
lw_expect_eq "$(ifups)" 1 "ifup wwan events before the respawn"
pass_at 3399 3400
lw_expect_eq "$(snap_ifups 3399)" 1 "ifup wwan events 1799 s after the 1st, in the new process"
lw_expect_eq "$(chain)" "2 3400" "chain after the respawn"
expect_line 1 "IPv4 lost for 40 min while IPv6 works, ifup wwan, reconnect 2 of 3" "line of the 2nd reconnect after the respawn"

# a boot ends the chain (the state is in RAM): a loss after it waits its 10 min again
failing
pass_at 1000 1600
rm -rf /var/run/lw-linkwatch /var/run/lw-family
lk_v6result $SID - 70 answer
pass_at 60 659 660
lw_expect_eq "$(snap_ifups 659)" 1 "ifup wwan events 599 s into the loss after the boot"
lw_expect_eq "$(snap_ifups 660)" 2 "ifup wwan events 600 s into the loss after the boot"
lw_expect_eq "$(chain)" "1 660" "chain of the new boot"

# the working time (R49j): 60 min of IPv4 without a break end the chain, a pass every 150 s watches it.
# A new loss after it starts a new chain, the 1st reconnect again.
failing
# shellcheck disable=SC2046
pass_at 1000 1600 "1700|$HEAL" $(seqs 1850 150 5150) 5300 5450 "5600|$LOSE" 6199 6200
lw_expect_eq "$(snap_chain 1700)" "1 1600" "chain while IPv4 is working again"
lw_expect_eq "$(snap_chain 5150)" "1 1600" "chain after 3450 s of a working IPv4"
lw_expect_eq "$(snap_chain 5300)" - "chain after 3600 s of a working IPv4"
lw_expect_eq "$(snap_ifups 6199)" 1 "ifup wwan events 599 s into the new loss"
lw_expect_eq "$(snap_ifups 6200)" 2 "ifup wwan events 600 s into the new loss"
expect_line 1 "IPv4 lost for 10 min while IPv6 works, ifup wwan, reconnect 1 of 3" "line of the 1st reconnect of the new chain"

# an observed `wwan down` breaks the working time, also when the next look comes within 180 s
failing
# shellcheck disable=SC2046
pass_at 1000 1600 "1700|$HEAL" $(seqs 1850 150 2900) "3000|$WWAN_DOWN" "3010|$WWAN_UP" $(seqs 3150 150 6450) 6600 6750
lw_expect_eq "$(snap_chain 3000)" "1 1600" "chain after the pass that saw wwan down"
lw_expect_eq "$(snap_chain 5400)" "1 1600" "chain 3700 s after the first healthy look, with wwan down in between"
lw_expect_eq "$(snap_chain 6600)" "1 1600" "chain 3590 s after wwan came back"
lw_expect_eq "$(snap_chain 6750)" - "chain 3740 s after wwan came back"

# An unreadable QMI status is a break even when the healthy looks around it are less than 180 s apart.
failing
# shellcheck disable=SC2046
pass_at 1000 1600 "1700|$HEAL" $(seqs 1850 150 5150) \
    "5220|echo garbage >$T/uqmi/q-data" "5300|rm $T/uqmi/q-data"
lw_expect_eq "$(chain)" "1 1600" "chain after an unreadable IPv4 status"

# a loss the watcher restores in place breaks it too
failing
# shellcheck disable=SC2046
pass_at 1000 1600 "1700|$HEAL" $(seqs 1850 150 2900) "3000|$LOSE; rm -f $T/uqmi/q-start" $(seqs 3150 150 6900)
lk_lines | grep -q "restored in place" || lw_fail "the in-place restore: $(lk_lines)"
lw_expect_eq "$(snap_chain 6600)" "1 1600" "chain 3450 s after an in-place restore"
lw_expect_eq "$(snap_chain 6900)" - "chain after an hour from the in-place restore"

# the working time belongs to the session it began in (R49h): when netifd shows another native session
# the hour starts over (the count and the gaps stay), so the chain still stands 2400 s after the change
# and ends 3600 s after the first healthy look of the new session
failing
# shellcheck disable=SC2046
pass_at 1000 1600 "1700|$HEAL" $(seqs 1850 150 2900) "3000|$OTHER_SESSION" $(seqs 3150 150 6450) 6600 6750
lw_expect_eq "$(snap_chain 2900)" "1 1600" "chain before the session changed"
lw_expect_eq "$(snap_chain 5400)" "1 1600" "chain 3700 s after the first healthy look, with another session in between"
lw_expect_eq "$(snap_chain 6450)" "1 1600" "chain 3450 s after the first look of the new session"
lw_expect_eq "$(snap_chain 6600)" - "chain 3600 s after the first look of the new session"

# a look after a gap is no continuous hour (nobody saw what happened): the working time starts over
failing
# shellcheck disable=SC2046
pass_at 1000 1600 "1700|$HEAL" 5400 $(seqs 5550 150 9150)
lw_expect_eq "$(snap_chain 5400)" "1 1600" "chain after one look at the end of a gap of 3700 s"
lw_expect_eq "$(snap_chain 8850)" "1 1600" "chain 3450 s after that look"
lw_expect_eq "$(snap_chain 9150)" - "chain 3750 s after that look"

# the loss time belongs to the session (R49h): a new session that loses IPv4 starts its own 10 min,
# while the count and the gap of the chain carry over. A chain primed with one old reconnect.
failing
mkdir -p /var/run/lw-linkwatch
echo "1 100" >"$CHAIN"
pass_at 5000 5020 5599 5600
lw_expect_eq "$(snap_ifups 5020)" 0 "ifup wwan events at the first look after the loss (a gap that is long over)"
lw_expect_eq "$(snap_ifups 5599)" 0 "ifup wwan events 599 s into the loss of a new session"
lw_expect_eq "$(snap_ifups 5600)" 1 "ifup wwan events 600 s into the loss of a new session"
lw_expect_eq "$(chain)" "2 5600" "chain of a new session"
failing
pass_at 1000 1600 "1700|$OTHER_SESSION; $LOSE" 2300 3399 3400
lw_expect_eq "$(snap_ifups 2300)" 1 "ifup wwan events 600 s into the loss of the second session (the gap of the chain holds)"
lw_expect_eq "$(snap_ifups 3399)" 1 "ifup wwan events 1799 s after the 1st"
lw_expect_eq "$(snap_ifups 3400)" 2 "ifup wwan events 1800 s after the 1st, in the second session"
expect_line 1 "IPv4 lost for 28 min while IPv6 works, ifup wwan, reconnect 2 of 3" "line of the reconnect of the second session"

# `once` (a manual check, or beside the service) reports what the service would do and never writes the
# chain or runs `ifup` for it
failing
pass_at 1000 1599
at 1600
lw-linkwatch once
lw_expect_eq "$(ifups)" 0 "ifup wwan events of a once at the due second"
lw_expect_eq "$(chain)" - "chain after a once at the due second"
lw_expect_eq "$(dues)" 1 "report lines of a once at the due second"
expect_line 1 "IPv4 lost for 10 min while IPv6 works, reconnect 1 of 3 is due; only the service makes it" "report of a once"
[ ! -e "$MARK" ] || lw_fail "a once wrote the negotiation mark"
# the service and a once at the very same time: the reconnect goes out once
lw-linkwatch once &
once_pid=$!
pass_at 1600
wait "$once_pid"
lw_expect_eq "$(ifups)" 1 "ifup wwan events of the service and a once together"
lw_expect_eq "$(reconnects)" 1 "reconnect lines of the service and a once together"
lw_expect_eq "$(chain)" "1 1600" "chain of the service and a once together"
# a once after the reconnect changes nothing; on the next due second it reports and changes nothing
d0=$(dues)
lw-linkwatch once
lw_expect_eq "$(dues)" "$d0" "report lines of a once right after the reconnect"
at 3400
lw-linkwatch once
lw_expect_eq "$(ifups)" 1 "ifup wwan events of a once after the reconnect"
lw_expect_eq "$(chain)" "1 1600" "chain after a once on the next due second"
lw_expect_eq "$(dues)" $((d0 + 1)) "report lines after a once on the next due second"
expect_line 1 "IPv4 lost for 40 min while IPv6 works, reconnect 2 of 3 is due; only the service makes it" "report of a once on the 2nd"

# no chain, no reconnect where the rule does not apply
# an IPv4-only session: the `ifup` after 20 s of today, nothing after it
lk_setup
lk_lost
echo '"Call failed"' >"$T/uqmi/q-start"
pass_at 1000 100000 200000
lw_expect_eq "$(ifups)" 1 "ifup wwan events of an IPv4-only session"
lw_expect_eq "$(chain)" - "chain of an IPv4-only session"
# IPv6 silent in this session: the `ifup` of R49d, not part of the chain
failing
lk_v6result $SID - 1005 none
pass_at 1000 100000
lw_expect_eq "$(ifups)" 1 "ifup wwan events with IPv6 silent"
lw_expect_eq "$(chain)" - "chain of an incident with IPv6 silent"
# an IPv6-only session (no native IPv4 call): the watcher does nothing
lk_setup
lk_netifd up v6
echo up >"$T/uqmi/session-18"
lk_lost
pass_at 1000 100000
lw_expect_eq "$(ifups)" 0 "ifup wwan events of an IPv6-only session"
lw_expect_eq "$(chain)" - "chain of an IPv6-only session"
# IPv6 lost while IPv4 works: the LAN follows, wwan stays
dual_ok
echo down >"$T/uqmi/session-18"
pass_at 1000 100000
lw_expect_eq "$(ifups)" 0 "ifup wwan events with IPv6 lost and IPv4 working"
lw_expect_eq "$(chain)" - "chain with IPv6 lost"
# a connected call: nothing is counted, and no file is made
dual_ok
pass_at 1000 5000 100000
lw_expect_eq "$(chain)" - "chain of a healthy session"
lw_expect_eq "$(lk_info)" 0 "watcher syslog lines of a healthy session"

# a half IPv6 call (only a client) is no IPv6 call for the reconnect, though R49d keeps it as a sibling
failing
lk_netifd up v4half
echo up >"$T/uqmi/session-18"
pass_at 1000 1700 100000
lw_expect_eq "$(ifups)" 0 "ifup wwan events with a half IPv6 call"
lw_expect_eq "$(chain)" - "chain with a half IPv6 call"

# a respawn of the watcher: the marker keeps the second the incident began (R49d), so a family result
# from before the incident does not hold the reconnect, and one from after it still does
failing
pass_at 1000
grep -qx "$SID - kept 1000" /var/run/lw-linkwatch/escalated || lw_fail "the marker: $(cat /var/run/lw-linkwatch/escalated)"
lk_v6result $SID - 990 none
pass_at 1700
lw_expect_eq "$(ifups)" 1 "ifup wwan events with a silence from before the incident"
failing
pass_at 1000
lk_v6result $SID - 1100 none
pass_at 1700
lw_expect_eq "$(ifups)" 0 "ifup wwan events with a silence from after the incident"
# markers of the older kind and unusable ones feed nothing and break nothing
for marker in "$SID -" "$SID - kept" "$SID - kept 08x" "$SID - kept 0900" "$SID - kept 99999999999"; do
    failing
    pass_at 1000
    echo "$marker" >/var/run/lw-linkwatch/escalated
    pass_at 1700 100000
    lw_expect_eq "$(ifups)" 0 "ifup wwan events with the marker '$marker'"
done

# A malformed birth in a kept marker must not stop ash before it can handle a fresh incident.
failing
LK_IFBIRTH=900 lk_dual
pass_at 1000
echo "$SID 008 kept 1000" >/var/run/lw-linkwatch/escalated
pass_at 1700
lw_expect_eq "$(ifups)" 0 "ifup with an invalid birth, before the new incident is due"
grep -qx "$SID 900 kept 1700" /var/run/lw-linkwatch/escalated ||
    lw_fail "the watcher did not replace the invalid escalation marker"

# a chain the service cannot read blocks the reconnect (a damaged state never gives the budget back),
# is left as it is, and never ends the shell in an arithmetic error
for line in garbage "0 100" "1 008" "1 12345678901" "100 5" "-1 5" "1 -" "1 5 extra" "1 05" "1 0x10" "" "1" \
    "$(printf '1 100\n2 900')"; do
    failing
    mkdir -p /var/run/lw-linkwatch
    printf '%s\n' "$line" >"$CHAIN"
    rc=0
    err=$(pass_at 1000 1700 100000 2>&1) || rc=$?
    lw_expect_eq "$rc" 0 "exit status with the chain '$line'"
    lw_expect_eq "$err" "" "stderr with the chain '$line'"
    lw_expect_eq "$(ifups)" 0 "ifup wwan events with the chain '$line'"
    lw_expect_eq "$(cat "$CHAIN")" "$line" "the unreadable chain is left as it is"
done
# a chain behind a link is no chain either
failing
mkdir -p /var/run/lw-linkwatch /tmp/elsewhere
echo "1 100" >/tmp/elsewhere/v4chain
ln -s /tmp/elsewhere/v4chain "$CHAIN"
pass_at 1000 1700 100000
lw_expect_eq "$(ifups)" 0 "ifup wwan events with the chain behind a link"
# a chain that is valid reads fine, the control of the lines above
failing
mkdir -p /var/run/lw-linkwatch
echo "1 100" >"$CHAIN"
pass_at 1000 1899 1900
lw_expect_eq "$(snap_ifups 1899)" 0 "ifup wwan events 1799 s after a chain's reconnect"
lw_expect_eq "$(snap_ifups 1900)" 1 "ifup wwan events with a chain that parses"

# guards: the watcher's brake (R49e), a start of wwan being negotiated (R14f), wwan-recover running.
# The reconnect waits and keeps the schedule.
failing
pass_at 1000 1500 "1600|echo 1900 >/var/run/lw-linkwatch/pause_until" 1800 1899 1900
lw_expect_eq "$(snap_ifups 1800)" 0 "ifup wwan events during the brake"
lw_expect_eq "$(snap_ifups 1899)" 0 "ifup wwan events one second before the brake is over"
lw_expect_eq "$(snap_ifups 1900)" 1 "ifup wwan events when the brake is over"
failing
pass_at 1000 1500 "1600|mkdir -p /var/run/lw-family; echo 1730 >$MARK" 1700 1729 1730
lw_expect_eq "$(snap_ifups 1729)" 0 "ifup wwan events while a start is negotiating"
lw_expect_eq "$(snap_chain 1729)" - "chain while a start is negotiating"
lw_expect_eq "$(snap_ifups 1730)" 1 "ifup wwan events when the start is over"
export LW_RECOVER_LOCK=/tmp/elsewhere-recover.lock
failing
ln -s "$$:0:0" "$LW_RECOVER_LOCK"
pass_at 1000 1600 1700 "1750|rm -f $LW_RECOVER_LOCK" 1800
lw_expect_eq "$(snap_ifups 1700)" 0 "ifup wwan events while wwan-recover runs"
lw_expect_eq "$(snap_chain 1700)" - "chain while wwan-recover runs"
lw_expect_eq "$(snap_ifups 1750)" 1 "ifup wwan events when wwan-recover is done"
# a lock whose process is gone is no run
failing
rm -f "$LW_RECOVER_LOCK"
ln -s "999999:0:0" "$LW_RECOVER_LOCK"
pass_at 1000 1600
lw_expect_eq "$(ifups)" 1 "ifup wwan events with a stale lock of wwan-recover"
rm -f "$LW_RECOVER_LOCK"
# wwan-recover starts after the reconnect wrote its mark and its reservation (the EDGE ladder's own
# `ifup`; the stand-in makes the lock appear only then): the reconnect looks at the lock once more after both, sees the run and leaves wwan to it; no count is used
echo $$ >"$T/live-pid"
mkdir -p "$T/bin"
cat >"$T/bin/readlink" <<'EOS'
#!/bin/sh
n=$(cat /lwtest/rl-n 2>/dev/null || echo 0)
echo $((n + 1)) >/lwtest/rl-n
if [ "$n" = 1 ] && [ -f /var/run/lw-family/negotiating ] && [ -f /var/run/lw-linkwatch/v4reserve ]; then
    ln -s "$(cat /lwtest/live-pid):0:0" /tmp/elsewhere-recover.lock
fi
exec /bin/busybox readlink "$@"
EOS
chmod +x "$T/bin/readlink"
failing
rm -f "$T/rl-n" "$LW_RECOVER_LOCK"
PATH=$T/bin:$PATH pass_at 1000 1600
[ "$(cat "$T/rl-n")" = 2 ] || lw_fail "the stand-in readlink was called $(cat "$T/rl-n") times, not 2 (guard, then after the mark and the reservation)"
lw_expect_eq "$(ifups)" 0 "ifup wwan events when wwan-recover started after the mark"
lw_expect_eq "$(chain)" - "chain when wwan-recover started after the mark"
rm -f "$T/bin/readlink" "$LW_RECOVER_LOCK"
unset LW_RECOVER_LOCK
# no directory of root for the mark, no reconnect and no count used
failing
pass_at 1000 1500 "1550|rm -rf /var/run/lw-family; : >/var/run/lw-family" 1600
lw_expect_eq "$(ifups)" 0 "ifup wwan events when the mark cannot be written"
lw_expect_eq "$(chain)" - "chain when the mark cannot be written"
rm -f /var/run/lw-family

# A directory at the mark path cannot reserve the start or consume a reconnect.
failing
pass_at 1000 "1600|mkdir $MARK"
lw_expect_eq "$(ifups)" 0 "ifup when the negotiation mark is a directory"
lw_expect_eq "$(chain)" - "chain when the negotiation mark is a directory"

# a reservation that cannot be written (the name is taken by a directory): no reconnect, no count used
failing
pass_at 1000 1500 "1550|mkdir -p /var/run/lw-linkwatch/v4reserve" 1600
lw_expect_eq "$(ifups)" 0 "ifup wwan events when the reservation cannot be written"
lw_expect_eq "$(chain)" - "chain when the reservation cannot be written"

# the session changes in the pass that would reconnect (R49h): no ifup, and the slot is not used
failing
cat >"$T/on-uqmi.session" <<'EOS'
#!/bin/sh
[ "$1" = settings ] || exit 0
sed -i 's/"cid_4":"17"/"cid_4":"99"/' /lwtest/ifstatus/wwan.json
EOS
chmod +x "$T/on-uqmi.session"
pass_at 1000 1500 "1600|cp $T/on-uqmi.session $T/on-uqmi"
lw_expect_eq "$(ifups)" 0 "ifup wwan events when the session changed in the pass"
lw_expect_eq "$(chain)" - "chain when the session changed in the pass"
rm -f "$T/on-uqmi" "$T/on-uqmi.session"
# the IPv6 call is gone from the session when the reconnect is due
failing
cat >"$T/on-uqmi.v6" <<'EOS'
#!/bin/sh
[ "$1" = settings ] || exit 0
sed -i 's/,"cid_6":"18","pdh_6":"3203210529"//' /lwtest/ifstatus/wwan.json
EOS
chmod +x "$T/on-uqmi.v6"
pass_at 1000 1500 "1600|cp $T/on-uqmi.v6 $T/on-uqmi"
lw_expect_eq "$(ifups)" 0 "ifup wwan events when the IPv6 call is gone"
lw_expect_eq "$(chain)" - "chain when the IPv6 call is gone"
rm -f "$T/on-uqmi" "$T/on-uqmi.v6"

# the session and the IPv6 result are looked at again right before the mark, after the guards: a change
# that comes while the guards read wwan-recover's lock (the stand-in readlink takes it as its cue)
# leaves the slot unused
for change in 's/,"cid_6":"18","pdh_6":"3203210529"//' 's/"cid_4":"17"/"cid_4":"99"/' silent; do
    failing
    cat >"$T/bin/readlink" <<EOS
#!/bin/sh
if [ ! -e /lwtest/rl-done ]; then
    case '$change' in
        silent) echo "$SID - 1000 none" >/var/run/lw-family/ipv6 ;;
        *) sed -i '$change' /lwtest/ifstatus/wwan.json ;;
    esac
    : >/lwtest/rl-done
fi
exec /bin/busybox readlink "\$@"
EOS
    chmod +x "$T/bin/readlink"
    rm -f "$T/rl-done"
    PATH=$T/bin:$PATH pass_at 1000 1600
    [ -e "$T/rl-done" ] || lw_fail "the stand-in readlink was not called"
    lw_expect_eq "$(ifups)" 0 "ifup wwan events when '$change' came between the guards and the mark"
    lw_expect_eq "$(chain)" - "chain when '$change' came between the guards and the mark"
    rm -f "$T/bin/readlink"
done

# a healthy pass with a chain costs no command that a healthy pass without one does not (R49f): the
# commands of passes 2 to 4 of a service, counted by wrappers, are the same with and without a chain,
# and none of them is `ls` or `rm`
trace() {
    dual_ok
    if [ "$1" = chain ]; then
        mkdir -p /var/run/lw-linkwatch
        echo "1 500" >"$CHAIN"
    fi
    rm -rf /tmp/count
    mkdir -p /tmp/count
    for c in ls rm mv mkdir ln cat sed readlink timeout uqmi ifstatus jsonfilter uci ip date sleep head tail cut logger; do
        real=$(command -v "$c" 2>/dev/null) || continue
        printf '#!/bin/sh\necho %s >>"$LW_TEST/cmds"\nexec %s "$@"\n' "$c" "$real" >"/tmp/count/$c"
        chmod +x "/tmp/count/$c"
    done
    : >"$T/cmds"
    cat >"$T/on-sleep" <<'HOOK'
#!/bin/sh
[ "$(tail -n 1 /lwtest/sleeps)" = "sleep 7" ] && echo -- >>/lwtest/cmds
exit 0
HOOK
    chmod +x "$T/on-sleep"
    PATH=/tmp/count:$PATH LW_LINKWATCH_PERIOD=7 LW_LINKWATCH_PASSES=4 lw-linkwatch run
    rm -f "$T/on-sleep"
    # the commands of pass N, counted by name
    for n in 2 3 4; do
        awk -v n="$n" 'BEGIN { s = 1 } /^--$/ { s++; next } s == n' "$T/cmds" | sort | uniq -c | sed 's/^ *//' >"$T/cmds.$1.$n"
    done
}
trace plain
trace chain
[ -s "$T/cmds.plain.3" ] || lw_fail "the wrappers did not see the commands of a pass: the count proves nothing"
for n in 2 3 4; do
    lw_expect_eq "$(cat "$T/cmds.chain.$n")" "$(cat "$T/cmds.plain.$n")" "commands of healthy pass $n with a chain, against none"
    ! grep -qE ' (ls|rm)$' "$T/cmds.chain.$n" || lw_fail "healthy pass $n with a chain forks ls or rm: $(cat "$T/cmds.chain.$n")"
done
rm -rf /tmp/count

echo ok
