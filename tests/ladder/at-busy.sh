# Busy or dead AT port at a reboot threshold (R20a, D33): the reboot comes within 30 s and the
# snapshot says which modem reads it skipped.
# shellcheck source=tests/ladder/ladder.inc
. /fw/tests/ladder/ladder.inc

lw_net down down
lw_dns down down

# timed_run: one run, fails when it took more than 30 s or did not reboot.
timed_run() {
    _t0=$(date +%s)
    "$WR" >>"$T/out" 2>&1 || lw_fail "run failed"
    _dt=$(($(date +%s) - _t0))
    [ "$_dt" -le 30 ] || lw_fail "reboot after ${_dt}s"
    lw_expect_grep "$T/events" "^reboot"
    : >"$T/events"
}

state_set cycles=5 reboots=0 class=hang passive=0 uptime=4000
flock /tmp/lw-at.lock sleep 600 &
holder=$!
sleep 1
timed_run
lw_expect_grep "$SNAP" "modem reads skipped from AT+ZSNT? on: AT lock busy"
lw_expect_eq "$(state_get reboots)" 1 "reboots"
kill "$holder"

boot_sim 1000
state_set cycles=17 reboots=1 class=hang passive=0 uptime=4000
lw_at_override ALL HANG
timed_run
lw_expect_grep "$SNAP" "AT+ZSNT? -> no answer in 10 s; remaining modem reads skipped"
lw_expect_eq "$(state_get reboots)" 2 "reboots"

# A state that cannot be saved holds the reboot back, or every boot would hit the same threshold.
rm -f "$T/at/ALL"
state_set cycles=41 reboots=2 class=hang passive=0 uptime=4000
chmod 555 /etc
"$WR" >>"$T/out" 2>&1 || lw_fail "run failed"
chmod 755 /etc
lw_expect_no_grep "$T/events" "^reboot"
lw_expect_grep "$T/syslog" "state not saved to /etc/wwan-recover.state, reboot skipped"
lw_expect_eq "$(state_get reboots)" 2 "reboots kept"
check_format
echo ok
