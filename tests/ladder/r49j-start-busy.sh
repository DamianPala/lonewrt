# R49j, R16, R23: the ladder's three `ifup wwan` steps (EDGE entry, the LTE probe, the way back to EDGE)
# wait only while lw-linkwatch's reservation holds (`/var/run/lw-linkwatch/v4reserve`: a fixed deadline,
# at most 60 s ahead of the uptime read at the moment of the decision); they keep the ladder's counts and
# run in the next cycle. An ordinary start (the negotiation mark of qmi.sh) delays nothing, as on main; a
# deadline that is over, too far ahead, damaged or a link holds nothing.
# shellcheck source=tests/ladder/ladder.inc
. /fw/tests/ladder/ladder.inc

MARK=/var/run/lw-family/negotiating
RES=/var/run/lw-linkwatch/v4reserve
ifups() { grep -c '^ifup wwan$' "$T/events" || true; }
now() { cut -d. -f1 "$T/uptime"; }

# what each run gets before it starts: an ordinary mark (30 s ahead) in runs MARK_FROM..MARK_TO, a
# reservation in runs RES_FROM..RES_TO (the deadline RES_OFF s ahead, or the raw text RES_RAW, or a link
# when RES_RAW is `link`), and the clock moved by 5 s at the first ping of run ADV_RUN
MARK_FROM=0 MARK_TO=0 RES_FROM=0 RES_TO=0 RES_OFF=30 RES_RAW='' ADV_RUN=0
before_run() {
    rm -f "$MARK" "$RES"
    if [ "$run" -ge "$MARK_FROM" ] && [ "$run" -le "$MARK_TO" ]; then
        mkdir -p /var/run/lw-family
        echo $(($(now) + 30)) >"$MARK"
    fi
    if [ "$run" -ge "$RES_FROM" ] && [ "$run" -le "$RES_TO" ]; then
        mkdir -p /var/run/lw-linkwatch
        case $RES_RAW in
            '') echo $(($(now) + RES_OFF)) >"$RES" ;;
            link)
                echo $(($(now) + 30)) >/tmp/elsewhere-reserve
                ln -s /tmp/elsewhere-reserve "$RES"
                ;;
            *) printf '%s\n' "$RES_RAW" >"$RES" ;;
        esac
    fi
    if [ "$run" = "$ADV_RUN" ]; then : >"$T/pre/on"; else rm -f "$T/pre/on"; fi
}
# a ping that moves the clock by 5 s once when asked, as a slow probe of the cycle does
mkdir -p "$T/pre"
cat >"$T/pre/ping" <<'EOS'
#!/bin/sh
if [ -e /lwtest/pre/on ]; then
    rm -f /lwtest/pre/on
    awk '{ printf "%.2f %.2f\n", $1 + 5, $2 + 5 }' /lwtest/uptime >/lwtest/uptime.n && mv /lwtest/uptime.n /lwtest/uptime
fi
exec /fw/tests/ladder/stubs/ping "$@"
EOS
chmod +x "$T/pre/ping"
PATH=$T/pre:$PATH
export PATH

# fresh: a clean log, event list and run counter, the limit state, the first cycle after boot
fresh() {
    : >"$T/syslog"
    : >"$T/events"
    rm -f "$MARK" "$RES" /tmp/elsewhere-reserve
    MARK_FROM=0 MARK_TO=0 RES_FROM=0 RES_TO=0 RES_OFF=30 RES_RAW='' ADV_RUN=0
    lw_net down down
    lw_dns down down
    state_set cycles=300 reboots=6 class=hang passive=1 uptime=5000
    boot
    run=0
}
waits() { grep -c "wwan-recover: $1 waits" "$T/syslog" || true; }

# the first cycle after boot is a grace cycle (301), the EDGE entry is the second run (302)

# an ordinary negotiation mark delays nothing: the entry is where main has it
fresh
MARK_FROM=2 MARK_TO=3
runs 3
lw_expect_eq "$(wr_at 'EDGE enter: ')" 302 "EDGE entry with an ordinary mark live"
lw_expect_eq "$(waits 'EDGE enter')" 0 "waits with an ordinary mark live"
lw_expect_eq "$(ifups)" 1 "ifup wwan events of the EDGE entry with an ordinary mark live"

# a live reservation holds the entry and keeps the counts; the first run without it enters
fresh
RES_FROM=2 RES_TO=3
runs 3
lw_expect_eq "$(ifups)" 0 "ifup wwan events while the reservation holds"
lw_expect_eq "$(wr_at 'EDGE enter waits')" "302 303" "runs that waited for the reservation"
lw_expect_eq "$(wr_at 'EDGE enter: ')" "" "EDGE entries while the reservation holds"
lw_expect_eq "$(mode_now)" lte "mode while the reservation holds"
runs 1
lw_expect_eq "$(wr_at 'EDGE enter: ')" 304 "EDGE entry in the first run after the reservation"
lw_expect_eq "$(ifups)" 1 "ifup wwan events of the EDGE entry"
lw_expect_eq "$(mode_now)" edge "mode after the reservation"

# the bound: a deadline 60 s ahead holds, 61 s ahead is further than anybody reserves and holds nothing
fresh
RES_FROM=2 RES_TO=2 RES_OFF=60
runs 2
lw_expect_eq "$(wr_at 'EDGE enter waits')" 302 "a deadline at the bound holds"
fresh
RES_FROM=2 RES_TO=2 RES_OFF=61
runs 2
lw_expect_eq "$(wr_at 'EDGE enter: ')" 302 "a deadline one second over the bound holds nothing"
# far-future deadlines hold nothing, in every cycle
fresh
RES_FROM=1 RES_TO=9 RES_OFF=100000
runs 3
lw_expect_eq "$(wr_at 'EDGE enter: ')" 302 "a far-future deadline holds nothing"
fresh
RES_FROM=1 RES_TO=9 RES_RAW=99999999999
runs 3
lw_expect_eq "$(wr_at 'EDGE enter: ')" 302 "a deadline of 11 digits holds nothing"
# damaged files and a link hold nothing
for raw in garbage 012345 "1 2" 1000x " " link; do
    fresh
    RES_FROM=1 RES_TO=9 RES_RAW=$raw
    runs 3
    lw_expect_eq "$(wr_at 'EDGE enter: ')" 302 "the reservation file '$raw' holds nothing"
    lw_expect_eq "$(waits 'EDGE enter')" 0 "waits with the reservation file '$raw'"
done
# a deadline that the cycle's own probes pass (the clock moves 5 s inside the run) holds nothing: the
# uptime is read at the decision, not at the start of the cycle
fresh
RES_FROM=2 RES_TO=2 RES_OFF=3 ADV_RUN=2
runs 2
lw_expect_eq "$(wr_at 'EDGE enter: ')" 302 "a deadline passed during the cycle holds nothing"
lw_expect_eq "$(waits 'EDGE enter')" 0 "waits with a deadline passed during the cycle"

# the LTE probe after 72 cycles on EDGE, and the way back: as on main with an ordinary mark ...
fresh
MARK_FROM=74 MARK_TO=75
runs 100
lw_expect_eq "$(wr_at 'LTE probe: ')" 374 "probe with an ordinary mark live"
lw_expect_eq "$(wr_at 'EDGE back')" 376 "way back with an ordinary mark live"
lw_expect_eq "$(waits 'LTE probe')" 0 "probe waits with an ordinary mark live"
# ... and held by the reservation
fresh
RES_FROM=74 RES_TO=75
runs 100
lw_expect_eq "$(wr_at 'LTE probe waits')" "374 375" "runs of the probe that waited"
lw_expect_eq "$(wr_at 'LTE probe: ')" 376 "probe in the first run after the reservation"
lw_expect_eq "$(wr_at 'EDGE back')" 378 "back to EDGE after 2 probe cycles"
# the way back from a probe
fresh
RES_FROM=76 RES_TO=76
runs 100
lw_expect_eq "$(wr_at 'EDGE back waits')" 376 "run of the way back that waited"
lw_expect_eq "$(wr_at 'EDGE back: ')" 377 "way back in the first run after the reservation"
fresh
MARK_FROM=76 MARK_TO=76
runs 100
lw_expect_eq "$(wr_at 'EDGE back: ')" 376 "way back with an ordinary mark live"
check_format
echo ok
