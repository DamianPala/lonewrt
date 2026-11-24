# R77d, D198, D200, R23: in a session with an IPv6 call (IPv6 alone, translated, or dual stack) the
# recovery ladder counts IPv6 traffic of the session's own device that answered a connection since the
# previous cycle as online, as watchcat does (tests/watchcat/r77d-traffic.sh): a path that carries TCP
# over IPv6 but drops the echoes, or a dual-stack session that lost its IPv4 call, never reaches a
# reboot while the traffic flows, and a real loss takes the ladder as always. The measure is the
# per-device IPv6 counters of the kernel with ICMPv6 taken off: at least 4 packets in and 4 out per
# cycle. Quiet and unknown (the first cycle, no counters, another session) leave the probes to decide.
# A session without IPv6 reads no counters, and the LTE probe of R23 is not held by traffic.
# shellcheck source=tests/ladder/ladder.inc
. /fw/tests/ladder/ladder.inc

# before every cron run the counters of wwan0 rise by STEP (received, transmitted, ICMPv6 in, ICMPv6
# out); NO_STATS=1: there are none
STEP='0 0 0 0' NO_STATS=0
before_run() {
    [ "$NO_STATS" = 0 ] || return 0
    # shellcheck disable=SC2086
    snmp6-add wwan0 $STEP
}

# fresh KIND: a new boot well past the grace, a session of that kind whose probes get no answer
fresh() {
    boot_sim 1000
    rm -f "$STATE" "$T/at"/*
    : >/root/openwrt.log
    : >"$T/net-calls"
    : >"$T/events"
    : >"$T/reboot-runs"
    : >"$T/syslog"
    run=0
    STEP='0 0 0 0' NO_STATS=0
    lw_net down down
    lw_dns down down
    echo 0 >"$T/net/txbump"
    lw_session "$1"
    lw_reach_none
}

# --- active IPv6 traffic with no echo answer for twice the first threshold: no reboot, no failure
# left behind, on every session with IPv6, the dual stack that lost its IPv4 call included
for kind in v6 v6clat v6child dual; do
    fresh "$kind"
    STEP='60 60 0 0'
    runs 12
    lw_expect_eq "$(reboot_runs)" "" "R77d $kind: reboots while IPv6 traffic is answered"
    [ ! -e "$STATE" ] || lw_fail "R77d $kind: a failure is counted: $(cat "$STATE")"
    lw_expect_eq "$(mode_now)" lte "R77d $kind: mode"
    lw_expect_no_grep "$T/syslog" "REBOOT"
    lw_expect_no_grep "$T/syslog" "EDGE"

    # then both families are really lost: the traffic stops, the ladder repairs as before, the first
    # reboot at the sixth silent cycle, class hang
    STEP='0 0 0 0'
    runs 6
    lw_expect_eq "$(reboot_runs)" 18 "R77d $kind: the first reboot after the loss, at the sixth silent cycle"
    lw_expect_eq "$(state_get class)" hang "R77d $kind: class after the loss"
    lw_expect_eq "$(state_get reboots)" 1 "R77d $kind: reboots after the loss"
done

# traffic that returns in the middle of a failure ends it: no reboot at the threshold
for kind in v6 dual; do
    fresh "$kind"
    runs 4
    lw_expect_eq "$(state_get cycles)" 4 "R77d $kind: cycles of the silent link"
    STEP='60 60 0 0'
    runs 4
    [ ! -e "$STATE" ] || lw_fail "R77d $kind: the failure goes on with traffic: $(cat "$STATE")"
    lw_expect_eq "$(reboot_runs)" "" "R77d $kind: reboots when the traffic returned before the threshold"
    lw_expect_grep "$T/syslog" "online on LTE, failure over after 4 cycles"
done

# R77d: an ongoing failure on EDGE can reach the next reboot threshold while IPv6 carries traffic.
# Once the traffic stops, the overdue step can run.
fresh v6
STEP='60 60 0 0'
uci set network.wwan.modes=all
uci commit network
state_set cycles=15 reboots=1 class=hang passive=0 uptime=700
runs 1
lw_expect_eq "$(mode_now)" edge "R77d: active failure is on EDGE"
runs 3
lw_expect_eq "$(reboot_runs)" "" "R77d: reboot of a working IPv6 link on EDGE"
STEP='0 0 0 0'
runs 1
lw_expect_eq "$(reboot_runs)" 5 "R77d: overdue reboot after IPv6 traffic stops on EDGE"

# R23: the LTE probe after 72 cycles on EDGE is the repair of R23, not a restart for silence, and
# traffic does not hold it: the mode goes back to LTE-only at cycle 72 of the passive mode
fresh v6
STEP='60 60 0 0'
uci set network.wwan.modes=all
uci commit network
state_set cycles=40 reboots=6 class=hang passive=1 uptime=700
printf 'wd_ino=\nwd_base=0\nwd_seen=0\nedge_boot=1\nedge_cycles=70\nprobe=\n' >/tmp/wwan-recover.run
runs 1
lw_expect_eq "$(mode_now)" edge "R23: still on EDGE after one cycle"
runs 1
lw_expect_eq "$(mode_now)" lte "R23: the LTE probe is not held by IPv6 traffic"
lw_expect_grep "$T/syslog" "LTE probe: 72 cycles on EDGE"

# not traffic that was answered: one way only, a trickle, ICMPv6 only (advertisements, neighbour
# discovery and the probes themselves, which the totals count too)
for st in '60 0 0 0' '0 60 0 0' '3 3 0 0' '60 60 60 60' '63 63 60 60'; do
    for kind in v6 dual; do
        fresh "$kind"
        STEP=$st
        runs 6
        lw_expect_eq "$(reboot_runs)" 6 "R77d $kind: reboot with traffic '$st'"
        lw_expect_eq "$(state_get class)" hang "R77d $kind: class with traffic '$st'"
    done
done
# the same just above the minimum is traffic (4 packets of data next to 60 of ICMPv6)
fresh v6
STEP='64 64 60 60'
runs 12
lw_expect_eq "$(reboot_runs)" "" "R77d: 4 packets of data next to ICMPv6"

# unknown: no counters, and a new session. The first cycle of a session has no baseline, so it counts
# as offline; the next one is judged again
fresh v6
STEP='60 60 0 0' NO_STATS=1
runs 6
NO_STATS=0
lw_expect_eq "$(reboot_runs)" 6 "R77d: reboot with unreadable counters"
fresh v6
STEP='60 60 0 0'
runs 3
[ ! -e "$STATE" ] || lw_fail "R77d: a failure with traffic: $(cat "$STATE")"
sed -i 's/"cid_6":"18"/"cid_6":"19"/' "$T/ifstatus/wwan.json"
runs 1
lw_expect_eq "$(state_get cycles)" 1 "R77d: the first cycle of a new session has no baseline (unknown)"
runs 1
[ ! -e "$STATE" ] || lw_fail "R77d: the new session's second cycle is judged again: $(cat "$STATE")"

# a session without IPv6 reads no counters: the probes alone decide, the run file has no sample
for kind in v4 legacy; do
    fresh "$kind"
    STEP='60 60 0 0'
    runs 5
    lw_expect_no_grep /tmp/wwan-recover.run "^tr="
    runs 1
    lw_expect_eq "$(reboot_runs)" 6 "R77d $kind: reboot at cycle 6 whatever the counters say"
    lw_expect_eq "$(state_get class)" hang "R77d $kind: class"
done
check_format
echo ok
