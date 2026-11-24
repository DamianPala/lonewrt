# R76c, D186: a translation that fails or stops is set up again by the next look (the next event of
# the IPv6 child or the next run of wwan-recover), and repeated failures followed by a working setup
# leave no stale process, address, rule or route of the translation: no helper but the live one, one
# pid file that names it, one nat46 device, the rules of the one marker. The stock teardown returns
# early after a setup that failed before its marker and the helper keeps its pid file; the check ends
# what is left, and never signals a process that is not the helper. One check runs at a time.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/clat/helpers.inc
. /fw/tests/clat/helpers.inc

# the one translation that works: one helper that its pid file names, one device, the rules of its marker
one_translation() {
    lw_expect_eq "$(cl_live)" 1 "$1: live helpers"
    grep -qa 464xlatcfg "/proc/$(cat "$CL_PID" 2>/dev/null)/cmdline" 2>/dev/null || lw_fail "$1: the pid file does not name the helper"
    lw_expect_eq "$(cl_nat46)" 464-wwan_6_4 "$1: nat46 devices"
    lw_expect_eq "$(cl_rules | sort)" "from all lookup local pref 1
to 2001:db8:1::464 lookup prelocal pref 0" "$1: rules"
}

# a setup that fails three times, each leaving the helper and its pid file behind, then one that works
cl_setup
cl_outcome fail
for i in 1 2 3; do
    cl_tick
    lw_expect_eq "$CL_RC" 0 "failed setup $i: exit status"
    cl_clean_state "after failed setup $i"
done
lw_expect_eq "$(cl_adds)" 3 "three tries"
lw_expect_eq "$(cl_clat_lines)" 1 "three failed setups: one line ($(cat "$LOG"))"
grep -q 'the translation did not come up on 464-wwan_6_4; IPv6 works, trying again' "$LOG" || lw_fail "line: $(cat "$LOG")"
cl_outcome up
cl_tick
one_translation "failed setups, then a working one"
lw_expect_eq "$(cl_clat_lines)" 2 "the line of the working setup"
lw_expect_eq "$(cat "$T/events")" "" "no restart of wwan"

# the helper dies: the interface still says up, the pid file names a process that is gone
cl_setup
cl_tick
kill "$(cat "$CL_PID")"
i=0
while [ "$(cl_live)" != 0 ] && [ "$i" -lt 5 ]; do i=$((i + 1)); /bin/sleep 1; done
lw_expect_eq "$(cl_live)" 0 "the helper died"
cl_tick
one_translation "helper died"
lw_expect_eq "$(cl_adds)" 2 "helper died: interfaces added"
grep -q 'translated IPv4 stopped on 464-wwan_6_4, setting it up again' "$LOG" || lw_fail "helper died: line: $(cat "$LOG")"
lw_expect_eq "$(cl_clat_lines)" 3 "helper died: up, stopped, up ($(cat "$LOG"))"
lw_expect_eq "$(cat "$T/events")" "" "helper died: no restart of wwan"

# netifd drops the interface, the helper and its marker stay
cl_setup
cl_tick
rm -f "$T/ifstatus/wwan_6_4.json"
cl_tick
one_translation "interface gone"

# the interface is down and not being set up (a stopped protocol): set up from nothing
cl_setup
cl_tick
printf '{"up":false,"pending":false}\n' >"$T/ifstatus/wwan_6_4.json"
cl_tick
one_translation "interface down"

# the helper is alive but the interface is on another device: not the translation
cl_setup
cl_tick
printf '{"up":true,"pending":false,"l3_device":"other0"}\n' >"$T/ifstatus/wwan_6_4.json"
cl_tick
lw_expect_eq "$(cl_adds)" 2 "wrong device: made again"

# a setup that is still running in netifd is left alone ...
cl_setup
printf '{"up":false,"pending":true}\n' >"$T/ifstatus/wwan_6_4.json"
cl_tick
lw_expect_eq "$(cl_adds)" 0 "pending interface met: no second try"
lw_expect_eq "$(cat "$C/ubus-calls" 2>/dev/null)" "" "pending interface met: netifd not called"
# ... but not for ever: a flag netifd never clears is taken out after LW_CLAT_PENDING_MAX s
lw_uptime_add 60
cl_tick
lw_expect_eq "$(cl_adds)" 0 "pending for 60 s: still left alone"
lw_uptime_add 60
cl_tick
lw_expect_eq "$(cl_adds)" 1 "pending for 120 s: taken out and made again"
one_translation "stuck pending flag"

# the pid file names a process that is not the helper (its number was used again): that process
# lives on, the pid file goes
cl_setup
/bin/sleep 300 &
other=$!
echo "$other" >"$CL_PID"
cl_tick
kill -0 "$other" 2>/dev/null || lw_fail "the process the pid file named by chance was killed"
one_translation "stale pid file"
kill "$other" 2>/dev/null || :

# a setup that died after its marker: the rules and the marker are taken back before the next try
cl_setup
echo 2001:db8:1::464 >"$CL_ANY"
ip -6 rule del from all lookup local
ip -6 rule add from all lookup local pref 1
ip -6 rule add to 2001:db8:1::464 lookup prelocal pref 0
echo "add 464-wwan_6_4" >>"$CL_NAT"
cl_dns_off
cl_tick
cl_clean_state "stale marker, no DNS64"

# one check at a time: a tick that meets another check returns at once and does nothing
cl_setup
mkdir -p "$CL_DIR"
sh -c 'exec 9>"$1/lock"; flock 9; /bin/sleep 30' sh "$CL_DIR" &
holder=$!
i=0
while ! [ -e "$CL_DIR/lock" ] && [ "$i" -lt 5 ]; do i=$((i + 1)); /bin/sleep 1; done
/bin/sleep 1
cl_tick
lw_expect_eq "$CL_RC" 0 "tick at a busy lock: exit status"
lw_expect_eq "$(cl_adds)" 0 "tick at a busy lock: nothing done"
lw_expect_eq "$(cat "$C/dns-queries" 2>/dev/null)" "" "tick at a busy lock: no question"
lw_expect_eq "$(cat "$T/sleeps")" "" "tick at a busy lock: no wait"
# a new session's check waits for the other one, for 25 s at most, and goes on when it ends
cat >"$T/on-sleep" <<EOF2
#!/bin/sh
# the other check ends at the third nap
[ "\$(wc -l <"\$LW_TEST/sleeps")" -lt 3 ] || kill $holder 2>/dev/null || :
EOF2
chmod +x "$T/on-sleep"
cl_new
lw_expect_eq "$CL_RC" 0 "new at a busy lock: exit status"
lw_expect_eq "$(cl_adds)" 1 "new at a busy lock: did its work when the other ended"
one_translation "new after a wait"
# ... and gives up when the other does not end
cl_setup
mkdir -p "$CL_DIR"
sh -c 'exec 9>"$1/lock"; flock 9; /bin/sleep 60' sh "$CL_DIR" &
holder2=$!
/bin/sleep 1
cl_new
lw_expect_eq "$CL_RC" 0 "new at a lock that stays busy: exit status"
lw_expect_eq "$(cl_adds)" 0 "new at a lock that stays busy: nothing done"
lw_expect_eq "$(grep -c '^sleep 1$' "$T/sleeps")" 25 "new at a lock that stays busy: 25 s and no more"
kill "$holder2" "$holder" 2>/dev/null || :
echo ok
