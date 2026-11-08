# Run lock (R21a, D22): a second run during a live first one ends at once; a run stuck for more than
# 20 min and the lock of a run killed with kill -9 are taken over, the stuck process and its
# children are killed, and the cycle then works normally. Each run is bounded by its own timeout.
# shellcheck source=tests/ladder/ladder.inc
. /fw/tests/ladder/ladder.inc

LOCK=/tmp/wwan-recover.lock
lw_net down down
lw_dns down down

# start_stuck: a run that hangs in ping; waits for its lock and prints the pid from it.
start_stuck() {
    touch "$T/net/hang"
    "$WR" >>"$T/out" 2>&1 &
    _w=0
    until [ -L "$LOCK" ]; do
        _w=$((_w + 1))
        [ "$_w" -le 20 ] || lw_fail "stuck run never took the lock"
        sleep 1
    done
    readlink "$LOCK" | cut -d: -f1
}

# alive PID: running and not a zombie waiting to be reaped.
alive() {
    [ -r "/proc/$1/stat" ] || return 1
    ! grep -q '^[0-9]* ([^)]*) Z' "/proc/$1/stat"
}

stuck_sleeps() {
    _n=0
    for _p in $(pgrep -f 'sleep 3600'); do
        alive "$_p" && _n=$((_n + 1))
    done
    echo "$_n"
}

grep -q 'exec timeout -k 5 265 ' "$WR" || lw_fail "no run time limit"

pid=$(start_stuck)
t0=$(date +%s)
"$WR" >>"$T/out" 2>&1 || lw_fail "second run failed"
[ $(($(date +%s) - t0)) -le 2 ] || lw_fail "second run did not end at once"
lw_expect_grep "$T/syslog" "previous run (pid $pid) still active, exiting"
[ ! -e "$STATE" ] || lw_fail "second run wrote the state"
alive "$pid" || lw_fail "first run died"

rm -f "$T/net/hang"
lw_uptime_add 1300
"$WR" >>"$T/out" 2>&1 || lw_fail "takeover run failed"
lw_expect_grep "$T/syslog" "previous run (pid $pid) running for 1300s, killing it and taking the lock over"
sleep 1
! alive "$pid" || lw_fail "stuck run still alive"
lw_expect_eq "$(stuck_sleeps)" 0 "children of the stuck run"
lw_expect_eq "$(state_get cycles)" 1 "takeover run counted the cycle"
[ ! -e "$LOCK" ] || lw_fail "lock left after a normal run"

lw_uptime_add 300
pid=$(start_stuck)
kill -9 "$pid"
sleep 1
[ -L "$LOCK" ] || lw_fail "kill -9 should leave the lock behind"
lw_expect_eq "$(stuck_sleeps)" 1 "orphan of the killed run"
rm -f "$T/net/hang"
lw_uptime_add 300
"$WR" >>"$T/out" 2>&1 || lw_fail "run after kill -9 failed"
lw_expect_grep "$T/syslog" "previous run (pid $pid) is gone, taking the lock over"
sleep 1
lw_expect_eq "$(stuck_sleeps)" 0 "orphan killed with the dead run's process group"
lw_expect_eq "$(state_get cycles)" 2 "cycle after the takeover"
[ ! -e "$LOCK" ] || lw_fail "lock left after the takeover run"

# What the run's own timeout does at 265 s: TERM to its whole process group.
lw_uptime_add 300
pid=$(start_stuck)
pg=$(readlink "$LOCK" | cut -d: -f2)
[ -n "$pg" ] && [ "$pg" != "$pid" ] || lw_fail "lock has no process group of the timeout wrapper"
kill -TERM "-$pg"
sleep 1
rm -f "$T/net/hang"
! alive "$pid" || lw_fail "run survived TERM"
[ ! -e "$LOCK" ] || lw_fail "lock left after a run cut by its timeout"
lw_expect_grep "$T/syslog" "wwan-recover: run cut at its time limit"
lw_expect_eq "$(stuck_sleeps)" 0 "children of the cut run"
check_format
echo ok
