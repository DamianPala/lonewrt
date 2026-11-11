# R49c: USR1 goes to udhcpc only after the release is done. Two signals pending at once arrive in
# number order (USR1 first), and udhcpc would then renew and release and end without an address.
# After USR2 the watcher looks at the device address up to 25 times until it is gone; if it is still
# there it waits 1 s; with no address before the release there is nothing to watch and it waits 1 s.
# The stand-in kill (stubs/lwkill) records what the device and the clock showed when USR1 came.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc

# usr1 SAW SLEEPS LOOKS WHAT: the state at the moment of USR1
usr1() {
    lw_expect_eq "$(cat "$T/usr1-saw")" "$1" "device address at USR1, $4"
    lw_expect_eq "$(cat "$T/usr1-sleeps")" "$2" "naps before USR1, $4"
    lw_expect_eq "$(cat "$T/usr1-looks")" "$3" "looks at the address after USR2, $4"
}
restored() {
    lw_expect_eq "$(cat "$T/addr/wwan0")" $NEW_ADDR "address of wwan0, $1"
    lk_lines | grep -qE "restored in place after" || lw_fail "$1: info line: $(lk_lines)"
}

# the address leaves with the release: USR1 follows at once, no nap before it
lk_setup
lk_lost
pid=$(cat /var/run/udhcpc-wwan0.pid)
lw-linkwatch once
lw_expect_eq "$(cat "$EVENTS")" "kill USR2 $pid
kill USR1 $pid" "events, address gone at once"
usr1 gone 0 1 "address gone at once"
restored "address gone at once"

# the address leaves after a few looks: the watcher looks again, still no nap
lk_setup
lk_lost
echo 3 >"$T/release-delay"
lw-linkwatch once
usr1 gone 0 4 "address gone after 3 looks"
restored "address gone after 3 looks"

# the address changes instead of going (another lease in between): that counts as the release
lk_setup
lk_lost
echo 0 >"$T/release-delay"
echo 10.9.9.9 >"$T/release-replace"
lw-linkwatch once
usr1 present 0 1 "address replaced"
restored "address replaced"

# the address stays after 25 looks: one nap of 1 s, then USR1
lk_setup
lk_lost
touch "$T/release-never"
lw-linkwatch once
usr1 present 1 25 "address stays"
restored "address stays"
lw_expect_eq "$(grep -c '^kill' "$EVENTS")" 2 "signals sent when the address stays"

# no address before the release: nothing to watch, no look, one nap of 1 s, then USR1
lk_setup
lk_lost
: >"$T/addr/wwan0"
lw-linkwatch once
usr1 gone 1 0 "no address before"
restored "no address before"
echo ok
