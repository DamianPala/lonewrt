# R49d, R49f, R49h, D196, D200: with an IPv6 call next to the lost IPv4 call, a restore that fails
# for 20 s (or a missing network device name) ends with `ifup wwan` only when a family check of this
# session, taken after the loss, got no IPv6 answer. An answer, no result, an older one, one of
# another session, or one the watcher cannot read: IPv6 is kept, no ifup, no wildcard stop, one
# info line, and nothing more until a pass sees the session healthy.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc
SID=17/3203210528
ifups() { grep -c '^ifup wwan$' "$EVENTS" || true; }

# a dual-stack session whose IPv4 start never works; the clock is at 1000 s when the loss is seen
failing() {
    lk_setup
    lk_dual
    lk_lost
    echo '"Call failed"' >"$T/uqmi/q-start"
}
kept() {
    lw-linkwatch once
    lw_expect_eq "$(ifups)" 0 "ifup wwan events: $1"
    lw_expect_eq "$(cat "$EVENTS")" "" "events: $1"
    lw_expect_eq "$(lk_calls_of --stop-network)" 0 "stop calls: $1"
    lw_expect_eq "$(cat "$T/uqmi-calls.18" 2>/dev/null)" "" "calls on the IPv6 client: $1"
    lw_expect_eq "$(cat "$T/uqmi/session-18")" up "IPv6 call: $1"
    lw_expect_eq "$(lk_info)" 1 "watcher syslog lines: $1"
    lk_lines | grep -qE " lw-linkwatch: data session lost, not restored in place after 20 s, IPv6 kept, no ifup\$" ||
        lw_fail "info line ($1): $(lk_lines)"
    # the passes that follow do nothing more (R49d)
    : >"$CALLS"
    lw-linkwatch once
    lw-linkwatch once
    lw_expect_eq "$(lk_calls_of --start-network)" 0 "start calls after the incident: $1"
    lw_expect_eq "$(lk_info)" 1 "watcher syslog lines after more passes: $1"
}

# no result at all: the state of IPv6 is unknown, the sibling is kept
failing
kept "no family result"

# a result of silence for this session, taken after the loss: the one ifup
failing
lk_v6result $SID - 1005 none
lw-linkwatch once
lw_expect_eq "$(cat "$EVENTS")" "ifup wwan" "events with a session-matched silence"
lw_expect_eq "$(lk_calls_of --stop-network)" 0 "stop calls with a session-matched silence"
lk_lines | grep -qE " lw-linkwatch: data session lost, not restored in place after 20 s, ifup wwan\$" ||
    lw_fail "info line: $(lk_lines)"
lw_expect_eq "$(lk_info)" 1 "watcher syslog lines with the ifup"
lw-linkwatch once
lw_expect_eq "$(ifups)" 1 "ifup wwan events after another pass"

# the IPv6 answered
failing
lk_v6result $SID - 1005 answer
kept "IPv6 answered"

# silence, but taken before the loss was seen
failing
lk_v6result $SID - 990 none
kept "a result older than the loss"

# silence of another session (another client, or the same numbers of another start)
failing
lk_v6result 99/3203210528 - 1005 none
kept "a result of another session"
failing
lk_v6result 17/99 - 1005 none
kept "a result of another handle"

# results the watcher cannot use: this round's family result is unavailable
for line in '' 'none' "$SID - none" "$SID - x none" "$SID - 1005 unavailable" "$SID - 1005 NONE" "$SID - 1005"; do
    failing
    mkdir -p /var/run/lw-family
    printf '%s\n' "$line" >/var/run/lw-family/ipv6
    kept "an unusable result '$line'"
done
failing
mkdir -p /var/run/lw-family
mkdir /var/run/lw-family/ipv6
kept "a result that is not a file"

# R14g: the file is believed only in a directory of root that is no link (the control is the case of
# the session-matched silence above, with the same line in the same place)
failing
mkdir -p /tmp/elsewhere
echo "$SID - 1005 none" >/tmp/elsewhere/ipv6
ln -s /tmp/elsewhere /var/run/lw-family
kept "a silence behind a link in place of the family directory"
failing
: >/var/run/lw-family
kept "a file in place of the family directory"

# the birth of the session is compared when both sides have one: the same start, and another start
# with the same numbers
failing
LK_IFBIRTH=400
lk_netifd up dual
unset LK_IFBIRTH
lk_v6result $SID 400 1005 none
lw-linkwatch once
lw_expect_eq "$(ifups)" 1 "ifup wwan events with a silence of this start"
failing
LK_IFBIRTH=400
lk_netifd up dual
unset LK_IFBIRTH
lk_v6result $SID 700 1005 none
kept "a silence of another start with the same numbers"
failing
LK_IFBIRTH=400
lk_netifd up dual
unset LK_IFBIRTH
lk_v6result $SID 4x 1005 none
kept "a birth that is not a number"

# a new session after the incident is not held by its marker, and the sibling rule applies again
failing
lw-linkwatch once
lk_healthy
lw-linkwatch once
lw_expect_eq "$(lk_info)" 1 "watcher syslog lines after the healthy pass"
lk_lost
echo '"Call failed"' >"$T/uqmi/q-start"
lk_v6result $SID - 1100 none
lw-linkwatch once
lw_expect_eq "$(ifups)" 1 "ifup wwan events of the second incident with a fresh silence"

# R49f: a missing network device name is an exit that restarts wwan: with IPv6 next to it, the same
# rule. IPv4 alone keeps the line and the ifup of today.
nodev() {
    sed -i 's/"l3_device":"wwan0",//' "$T/ifstatus/wwan.json"
    rm -f "$T/ifstatus/wwan_4.json"
}
failing
nodev
lw-linkwatch once
lw_expect_eq "$(cat "$EVENTS")" "" "events without a device name and no IPv6 result"
lw_expect_eq "$(lk_calls_of --start-network)" 0 "start calls without a device name"
lk_lines | grep -qE " lw-linkwatch: data session lost, no network device name from netifd, IPv6 kept, no ifup\$" ||
    lw_fail "info line without a device name: $(lk_lines)"
lw_expect_eq "$(lk_info)" 1 "watcher syslog lines without a device name"

failing
nodev
lk_v6result $SID - 1005 answer
lw-linkwatch once
lw_expect_eq "$(cat "$EVENTS")" "" "events without a device name and an IPv6 answer"

failing
nodev
lk_v6result $SID - 1005 none
lw-linkwatch once
lw_expect_eq "$(cat "$EVENTS")" "ifup wwan" "events without a device name and IPv6 silent"
lk_lines | grep -qE " lw-linkwatch: data session lost, no network device name from netifd, ifup wwan\$" ||
    lw_fail "info line: $(lk_lines)"

lk_setup
lk_lost
nodev
lw-linkwatch once
lw_expect_eq "$(cat "$EVENTS")" "ifup wwan" "events without a device name in an IPv4-only session"
lk_lines | grep -qE " lw-linkwatch: data session lost, no network device name from netifd, ifup wwan\$" ||
    lw_fail "info line: $(lk_lines)"

# an IPv6 call that is there but whose state is unknown (no handle) counts as a sibling
lk_setup
lk_netifd up v4half
echo up >"$T/uqmi/session-18"
lk_lost
echo '"Call failed"' >"$T/uqmi/q-start"
kept "a client without a handle"
echo ok
