# R14f, D197: when the silence timer of wwan_soft runs out while a start of wwan is within its
# negotiation deadline, watchcat waits for that start up to a guard that ends with the deadline. A start
# that gives IPv4 before the deadline feeds the timer and nothing is restarted; one that hangs past the
# deadline is restarted once, after the guard. The handler's mark is /tmp/lw-family/negotiating, the
# second of the deadline on the uptime clock (qmi-edits/functions.sh).
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/watchcat/helpers.inc
. /fw/tests/watchcat/helpers.inc

# the world: a silent IPv4 link; the checks are at 1060 and 1120 and take 20 s each, so the timer (120 s
# from 1000) has run out at the end of the check of 1120, second 1140. A start whose deadline is 1170
# begins at 1100, in the middle of the silence. START_ENDS is the second at which it ends (its mark is
# removed, and the link answers) or never.
world() {
    wc_setup
    cat >"$T/on-sleep" <<EOS
#!/bin/sh
now=\$(cut -d. -f1 "\$LW_UPTIME_FILE")
if [ "\$now" -ge 1100 ] && [ ! -e "\$LW_TEST/started" ]; then
    mkdir -p /tmp/lw-family
    echo 1170 >/tmp/lw-family/negotiating
    : >"\$LW_TEST/started"
fi
if [ -n "$1" ] && [ "\$now" -ge "$1" ] && [ -e "\$LW_TEST/started" ] && [ ! -e "\$LW_TEST/ended" ]; then
    rm -f /tmp/lw-family/negotiating
    echo '4 wwan0 *' >"\$LW_TEST/net/paths"
    : >"\$LW_TEST/ended"
fi
EOS
    chmod +x "$T/on-sleep"
    wc_clock 1000
}

# no start at all: the timer runs out at 1140 and wwan is restarted then (R14), once in this window
wc_setup
wc_clock 1000
wc_run hook 1250
lw_expect_eq "$(wc_ifups)" 1140 "restart without a start running"

# the start publishes IPv4 at 1150, before its deadline: no restart
world 1150
wc_run hook 1400
lw_expect_eq "$(wc_ifups)" "" "restarts when the start ends before its deadline"
lw_expect_eq "$(sed -n 's/^\([0-9]*\) ping .*/\1/p' "$WCP" | awk '$1 > 1140 && $1 < 1160' | head -n 1)" 1150 "the check right after the start (second)"

# the start hangs past its deadline: wwan is restarted once, after the guard (the deadline 1170 and the
# check that follows it, which gets no answer either)
world ''
wc_run hook 1290
lw_expect_eq "$(wc_ifups | wc -l)" 1 "restarts of a start that hangs past its deadline: $(wc_ifups | tr '\n' ' ') $(cat "$WCP" | tr '\n' '|')"
[ "$(wc_ifups)" -ge 1170 ] || lw_fail "the restart came at $(wc_ifups), before the end of the guard (1170)"
[ "$(wc_ifups)" -le 1200 ] || lw_fail "the restart came at $(wc_ifups), long after the guard"

# a mark that is already past its deadline (a start that was killed) holds nothing back
wc_setup
mkdir -p /tmp/lw-family
echo 900 >/tmp/lw-family/negotiating
wc_clock 1000
wc_run hook 1250
lw_expect_eq "$(wc_ifups)" 1140 "restart with an old mark"
# and a mark that is not a number
wc_setup
mkdir -p /tmp/lw-family
echo junk >/tmp/lw-family/negotiating
wc_clock 1000
wc_run hook 1250
lw_expect_eq "$(wc_ifups)" 1140 "restart with a mark that is no number"
