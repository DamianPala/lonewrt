# R49g: at the debug level a heartbeat line every 5 minutes with the passes, the failed or slow uqmi
# calls and the slowest answer since the last one; the service loop naps LW_LINKWATCH_PERIOD seconds
# between passes. Healthy passes write nothing else, and at the info level nothing at all.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc
beats() { grep -c 'lw-linkwatch: heartbeat' "$T/syslog.prio" || true; }

# info level: 130 passes, 11 minutes, silence
lk_setup
LW_LINKWATCH_PASSES=130 lw-linkwatch run
lw_expect_eq "$(cat "$LKS")" "" "syslog of a healthy run at the info level"
lw_expect_eq "$(sort "$T/sleeps" | uniq -c | tr -s ' ')" " 129 sleep 5" "naps of the loop"

# debug level, one slow answer in the first ten minutes
lk_setup
uci set lonewrt.log=log
uci set lonewrt.log.level=debug
uci commit lonewrt
# nap 10 plants the slow answer, nap 11 takes it away again
cat >"$T/on-sleep" <<'HOOK'
#!/bin/sh
n=$(cat /lwtest/naps 2>/dev/null || echo 0)
n=$((n + 1))
echo $n >/lwtest/naps
[ "$n" != 10 ] || echo '@SLOW 4' >/lwtest/uqmi/q-data
[ "$n" != 11 ] || rm -f /lwtest/uqmi/q-data
HOOK
chmod +x "$T/on-sleep"
LW_LINKWATCH_PASSES=125 lw-linkwatch run
lw_expect_eq "$(beats)" 2 "heartbeat lines in 10 min"
lk_debug_lines | grep -F heartbeat | head -n 1 | grep -qF "heartbeat: 61 passes, 1 failed or slow uqmi calls, slowest answer 4000 ms" ||
    lw_fail "first heartbeat: $(lk_debug_lines | grep -F heartbeat)"
lk_debug_lines | grep -F heartbeat | tail -n 1 | grep -qF "heartbeat: 60 passes, 0 failed or slow uqmi calls, slowest answer 0 ms" ||
    lw_fail "second heartbeat: $(lk_debug_lines | grep -F heartbeat)"
# the slow call itself is in the log, and there is nothing else: no line of a healthy pass
lw_expect_eq "$(lk_debug_lines | grep -vcF -e heartbeat -e 'uqmi data: answer')" 0 "other lines of the watcher"
lk_debug_lines | grep -qF "uqmi data: answer '\"connected\"', exit 0, 4000 ms" || lw_fail "no line for the slow call"
lw_expect_eq "$(grep -c ' lw-linkwatch: ' "$LKS")" "$(lk_debug_lines | wc -l | tr -d ' ')" "no info line in the run"

# a different period
lk_setup
LW_LINKWATCH_PERIOD=7 LW_LINKWATCH_PASSES=3 lw-linkwatch run
lw_expect_eq "$(cat "$T/sleeps")" "sleep 7
sleep 7" "naps with LW_LINKWATCH_PERIOD=7"
echo ok
