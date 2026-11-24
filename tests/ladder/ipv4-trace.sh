# R77, R77d: the recovery ladder on a session with IPv4 only, the owner's forced-IPv4 router, makes the
# same decisions as before the traffic measure: the same pings, syslog lines, events, state and run
# file in every cycle of a healthy spell, a failure up to its first reboot, and a recovery. The trace
# is compared with tests/ladder/ipv4-trace.golden, made with the script of the image before the
# traffic measure existed (commit e504f61). With /fw/tests/.out/old-wwan-recover present (a copy of
# that script) the test runs it and prints the trace instead, which is how the golden file is made
# and checked again:
#   tests/rootfs/run.sh tests/ladder/ipv4-trace.sh > tests/ladder/ipv4-trace.golden
# Even with counters of the IPv6 kind lying around, a session without IPv6 reads none.
# shellcheck source=tests/ladder/ladder.inc
. /fw/tests/ladder/ladder.inc

OLD=/fw/tests/.out/old-wwan-recover
[ ! -f "$OLD" ] || WR=$OLD
snmp6-add wwan0 100 100 0 0

boot_sim 1000
rm -f "$STATE" "$T/at"/*
: >/root/openwrt.log
: >"$T/net-calls"
: >"$T/events"
: >"$T/syslog"
lw_net down down
lw_dns down down
echo 0 >"$T/net/txbump"
lw_session v4
OUT=$T/trace
: >"$OUT"

# one cron run, then everything it decided
step() {
    runs 1
    {
        echo "--- run $run"
        cat "$STATE" 2>/dev/null || echo "(no state)"
        grep -v '^wd_ino=' /tmp/wwan-recover.run 2>/dev/null || echo "(no run file)"
        echo "- events"
        cat "$T/events"
        echo "- pings"
        cat "$T/net-calls"
        echo "- log"
        sed 's/^[0-9]* //' "$T/syslog"
    } >>"$OUT"
    : >"$T/events"
    : >"$T/net-calls"
    : >"$T/syslog"
}

# healthy, silent for six cycles up to the first reboot, healthy again, silent with a partial answer,
# the operator DNS answering with traffic going out (class account), and healthy again
lw_reach_none
lw_reach 4 wwan0
for _ in 1 2 3; do step; done
lw_reach_none
for _ in 1 2 3 4 5 6 7; do step; done
lw_reach 4 wwan0
for _ in 1 2; do step; done
lw_reach_none
lw_dns up down
echo 4 >"$T/net/txbump"
for _ in 1 2 3; do step; done
lw_reach 4 wwan0
for _ in 1 2; do step; done

if [ -f "$OLD" ]; then
    cat "$OUT"
    exit 0
fi
cmp -s "$OUT" /fw/tests/ladder/ipv4-trace.golden ||
    lw_fail "the trace of an IPv4-only session differs from the golden one: $(cmp "$OUT" /fw/tests/ladder/ipv4-trace.golden 2>&1)"
echo ok
