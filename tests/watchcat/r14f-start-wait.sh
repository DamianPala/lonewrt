# R14f, D197: when the silence timer of wwan_soft runs out while a start of wwan is within its
# negotiation deadline, watchcat waits for that start up to a guard that ends with the deadline. A start
# that gives IPv4 before the deadline feeds the timer and nothing is restarted; one that hangs past the
# deadline is restarted once, after the guard. The handler's mark is /var/run/lw-family/negotiating, the
# second of the deadline on the uptime clock (qmi-edits/functions.sh).
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/watchcat/helpers.inc
. /fw/tests/watchcat/helpers.inc

# the world: a silent IPv4 link; the checks are at 1060 and 1120 and take 20 s each, so the timer (120 s
# from 1000) has run out at the end of the check of 1120, second 1140. A start whose deadline is 1170
# begins at 1100, in the middle of the silence. START_ENDS is the second at which it ends (its mark is
# removed, and the link answers) or never; $2 is the deadline in its mark (default 1170).
world() {
    wc_setup
    cat >"$T/on-sleep" <<EOS
#!/bin/sh
now=\$(cut -d. -f1 "\$LW_UPTIME_FILE")
if [ "\$now" -ge 1100 ] && [ ! -e "\$LW_TEST/started" ]; then
    mkdir -p /var/run/lw-family
    echo ${2:-1170} >/var/run/lw-family/negotiating
    : >"\$LW_TEST/started"
fi
if [ -n "$1" ] && [ "\$now" -ge "$1" ] && [ -e "\$LW_TEST/started" ] && [ ! -e "\$LW_TEST/ended" ]; then
    rm -f /var/run/lw-family/negotiating
    : >"\$LW_TEST/ended"
fi
if [ -e "\$LW_TEST/ended" ] && [ "\$now" -ge "${3:-${1:-99999}}" ]; then
    echo '4 wwan0 *' >"\$LW_TEST/net/paths"
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

# Without an address ping fails instantly until DHCP catches up.
world 1150 1170 1154
: >"$T/ping-fast"
wc_run hook 1180
lw_expect_eq "$(wc_ifups)" "" "restart before the address arrived"
lw_expect_grep "$WCP" "^1154 ping "

# Settle ends at 20 s or the mark's deadline, whichever comes first.
for row in '1179 1170' '1153 1153'; do
    deadline=${row% *}
    restart=${row#* }
    world 1150 "$deadline" 1190
    : >"$T/ping-fast"
    wc_run hook 1200
    lw_expect_eq "$(wc_ifups)" "$restart" "restart at the settle limit"
done

# the start hangs past its deadline: wwan is restarted once, after the guard (the deadline 1170; a mark
# that lasts to its deadline leaves no settle window, so no check follows it)
world ''
wc_run hook 1290
lw_expect_eq "$(wc_ifups | wc -l)" 1 "restarts of a start that hangs past its deadline: $(wc_ifups | tr '\n' ' ') $(cat "$WCP" | tr '\n' '|')"
[ "$(wc_ifups)" -ge 1170 ] || lw_fail "the restart came at $(wc_ifups), before the end of the guard (1170)"
[ "$(wc_ifups)" -le 1200 ] || lw_fail "the restart came at $(wc_ifups), long after the guard"

# a mark that is already past its deadline (a start that was killed) holds nothing back
wc_setup
mkdir -p /var/run/lw-family
echo 900 >/var/run/lw-family/negotiating
wc_clock 1000
wc_run hook 1250
lw_expect_eq "$(wc_ifups)" 1140 "restart with an old mark"
# and a mark that is not a number
wc_setup
mkdir -p /var/run/lw-family
echo junk >/var/run/lw-family/negotiating
wc_clock 1000
wc_run hook 1250
lw_expect_eq "$(wc_ifups)" 1140 "restart with a mark that is no number"

# R14f, R73h: a mark never holds watchcat back longer than a negotiation lasts. A deadline far in the
# future (a bad mark, one of a start that was killed and a clock that restarted, a number too long
# for the shell) is cut to 60 s from the check that found the timer run out (1140), so the restart
# comes between 1200 and a check later
for mark in 99999 5000000000 123456789012345678901234567890; do
    world '' "$mark"
    wc_run hook 1400
    lw_expect_eq "$(wc_ifups | wc -l)" 1 "restarts with the mark $mark: $(wc_ifups | tr '\n' ' ')"
    [ "$(wc_ifups)" -ge 1200 ] || lw_fail "the restart with the mark $mark came at $(wc_ifups), before the end of the 60 s"
    [ "$(wc_ifups)" -le 1230 ] || lw_fail "the restart with the mark $mark came at $(wc_ifups), long after the 60 s"
done
# a deadline inside the 60 s is kept as it is
world '' 1150
wc_run hook 1250
[ "$(wc_ifups)" -ge 1150 ] && [ "$(wc_ifups)" -le 1180 ] || lw_fail "the restart with the mark 1150 came at $(wc_ifups)"

# the family directory is checked before its mark is believed: a link or a file holds nothing back,
# and the start is restarted as without a mark (R14)
wc_setup
wc_clock 1000
mkdir -p /tmp/elsewhere
echo 1170 >/tmp/elsewhere/negotiating
ln -s /tmp/elsewhere /var/run/lw-family
wc_run hook 1250
lw_expect_eq "$(wc_ifups)" 1140 "restart with the mark behind a link"
wc_setup
wc_clock 1000
: >/var/run/lw-family
wc_run hook 1250
lw_expect_eq "$(wc_ifups)" 1140 "restart with a file as the family directory"
# the same mark in a directory of root holds the restart back (the control of the cases above)
world 1150
wc_run hook 1400
lw_expect_eq "$(wc_ifups)" "" "restarts with the mark in a directory of root"
# and the test itself: a directory of another owner is no family directory (/proc belongs to nobody
# in this sandbox)
wc_setup
(
    # shellcheck source=src/files/usr/lib/lw/common.sh
    . /usr/lib/lw/common.sh
    lw_state_dir_ok /var/run/lw-family && exit 1
    mkdir -p /var/run/lw-family
    lw_state_dir_ok /var/run/lw-family || exit 2
    lw_state_dir_ok /proc && exit 3
    lw_state_dir_ok /nonexistent && exit 4
    ln -s /var/run/lw-family /tmp/famlink
    lw_state_dir_ok /tmp/famlink && exit 5
    exit 0
) || lw_fail "lw_state_dir_ok of common.sh, exit $?"
