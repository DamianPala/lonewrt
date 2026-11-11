# R49e: 3 restores within 10 minutes mean the restore does not hold: one info line, then no action for
# 10 minutes (no uqmi call at all), then the watcher acts again and the count starts from zero. Three
# restores spread over more than 10 minutes do not brake.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc
braked() { grep -c ' lw-linkwatch: 3 restores in 10 min, pausing for 10 min$' "$LKS" || true; }
restored() { grep -c 'restored in place' "$LKS" || true; }

lk_setup
for i in 1 2 3; do
    lk_lost
    lw-linkwatch once
    lw_expect_eq "$(restored)" $i "restores after incident $i"
    lw_uptime_add 60
done
lw_expect_eq "$(braked)" 1 "brake lines after 3 restores in 3 min"
lw_expect_eq "$(lk_info)" 4 "watcher syslog lines: 3 restores and the brake"

# a fourth loss inside the pause: no call to uqmi, no log line
lk_lost
: >"$CALLS"
lw-linkwatch once
lw-linkwatch once
lw_expect_eq "$(cat "$CALLS")" "" "uqmi calls during the pause"
lw_expect_eq "$(lk_info)" 4 "watcher syslog lines during the pause"
lw_expect_eq "$(grep -c '^ifup' "$EVENTS" || true)" 0 "ifup during the pause"

# the pause ends 10 min after the third restore (it was 180 s ago, 60 s since the last)
lw_uptime_add 420
lw-linkwatch once
lw_expect_eq "$(restored)" 3 "restores before the pause is over"
lw_uptime_add 120
lw-linkwatch once
lw_expect_eq "$(restored)" 4 "restores after the pause"
lw_expect_eq "$(braked)" 1 "brake lines: the count started again from zero"

# spread out: 3 restores 400 s apart stay below 3 in any 10 min
lk_setup
for i in 1 2 3; do
    lk_lost
    lw-linkwatch once
    lw_uptime_add 400
done
lw_expect_eq "$(restored)" 3 "restores 400 s apart"
lw_expect_eq "$(braked)" 0 "brake lines for restores 400 s apart"
echo ok
