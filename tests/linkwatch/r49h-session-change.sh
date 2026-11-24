# R49h: an incident belongs to the session it began in. When netifd's IPv4 call changes (another
# client or handle, none, or the same numbers of another start of the interface), the watcher
# ends it with the one line `the session changed` and no further uqmi call, signal or `ifup`; the
# ownership is checked before every modem call, before both signals to udhcpc and before the
# escalation. A marker of an earlier session does not hold a new one.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc
ifups() { grep -c '^ifup' "$EVENTS" || true; }
CHANGED=" lw-linkwatch: data session lost, the session changed, nothing more to do\$"

# on_nap N COMMAND: the world changes after the N-th nap of the watcher
on_nap() {
    cat >"$T/on-sleep" <<HOOK
#!/bin/sh
n=\$(cat /lwtest/naps 2>/dev/null || echo 0)
n=\$((n + 1))
echo \$n >/lwtest/naps
[ "\$n" != $1 ] || { $2; }
HOOK
    chmod +x "$T/on-sleep"
}
ended() {
    lw_expect_eq "$(ifups)" 0 "ifup events: $1"
    lw_expect_eq "$(grep -c '^kill' "$EVENTS" || true)" 0 "signals: $1"
    lw_expect_eq "$(lk_info)" 1 "watcher syslog lines: $1"
    lk_lines | grep -qE "$CHANGED" || lw_fail "info line ($1): $(lk_lines)"
}
# swap_to DATA: the data of wwan that the next status read shows
swap_to() { printf '{"up":true,"l3_device":"wwan0","data":{%s}}\n' "$1" >"$T/next.json"; }

# another client, another handle, no IPv4 call any more, in the middle of an incident that cannot
# restore: the incident stops at the next look, the calls so far are all there is
for data in '"cid_4":"19","pdh_4":"3203210528"' '"cid_4":"17","pdh_4":"77"' '"cid_6":"18","pdh_6":"5"' ''; do
    lk_setup
    lk_lost
    echo '"Call failed"' >"$T/uqmi/q-start"
    swap_to "$data"
    on_nap 2 "cp /lwtest/next.json /lwtest/ifstatus/wwan.json"
    lw-linkwatch once
    ended "session changed to {$data}"
    lw_expect_eq "$(lk_calls_of --start-network)" 2 "start calls before the change {$data}"
    lw_expect_eq "$(lk_calls_of 'wds,19')" 0 "calls on the new client {$data}"
    : >"$CALLS"
    rm -f "$T/on-sleep"
done

# the same numbers of another start: only the birth tells (R49h), the interface came up again
lk_setup
LK_IFBIRTH=900
lk_netifd up
lk_lost
echo '"Call failed"' >"$T/uqmi/q-start"
on_nap 2 "echo 1003 >/lwtest/ifbirth"
lw-linkwatch once
ended "the same numbers from another start"
lw_expect_eq "$(lk_calls_of --start-network)" 2 "start calls before the new start"

# the same start all along: the birth follows the clock and changes nothing (20 s of incident)
lk_setup
LK_IFBIRTH=900
lk_netifd up
lk_lost
echo '"Call failed"' >"$T/uqmi/q-start"
lw-linkwatch once
lw_expect_eq "$(ifups)" 1 "ifup events of one start with a birth"
lk_lines | grep -qE "not restored in place after 20 s, ifup wwan\$" || lw_fail "info line: $(lk_lines)"

# before a modem call: the session changes right after the status read of the pass, so the
# settings read, the start and everything after it never go out
lk_setup
lk_lost
cat >"$T/on-uqmi" <<'HOOK'
#!/bin/sh
[ "$1" != data ] || printf '{"up":true,"l3_device":"wwan0","data":{"cid_4":"19","pdh_4":"1"}}\n' >/lwtest/ifstatus/wwan.json
HOOK
chmod +x "$T/on-uqmi"
lw-linkwatch once
lw_expect_eq "$(lk_calls_of --get-current-settings)" 0 "settings reads after the session changed"
lw_expect_eq "$(lk_calls_of --start-network)" 0 "start calls after the session changed"
lw_expect_eq "$(lk_calls_of 'wds,19')" 0 "calls on the new client"
lw_expect_eq "$(cat "$EVENTS")" "" "events"
lw_expect_eq "$(lk_info)" 0 "watcher syslog lines: no incident had begun"

# before the signals: after the release the session changed, so the renew is not sent
lk_setup
lk_lost
cat >"$T/on-kill" <<'HOOK'
#!/bin/sh
[ "$1" != USR2 ] || printf '{"up":true,"l3_device":"wwan0","data":{"cid_4":"19","pdh_4":"1"}}\n' >/lwtest/ifstatus/wwan.json
HOOK
chmod +x "$T/on-kill"
pid=$(cat /var/run/udhcpc-wwan0.pid)
lw-linkwatch once
lw_expect_eq "$(cat "$EVENTS")" "kill USR2 $pid" "events: the renew of a session that is gone is not sent"
lk_lines | grep -qE "$CHANGED" || lw_fail "info line: $(lk_lines)"
lw_expect_eq "$(lk_calls_of 'wds,19')" 0 "calls on the new client after the release"

# R49c: a status read that fails between the release and the renew does not leave udhcpc released
lk_setup
lk_lost
cat >"$T/on-kill" <<'HOOK'
#!/bin/sh
[ "$1" != USR2 ] || rm -f /lwtest/ifstatus/wwan.json
HOOK
chmod +x "$T/on-kill"
pid=$(cat /var/run/udhcpc-wwan0.pid)
lw-linkwatch once
grep -qx "kill USR1 $pid" "$EVENTS" || lw_fail "the renew after a failed read is sent: $(cat "$EVENTS")"
lw_expect_eq "$(lk_calls_of --start-network)" 1 "start calls before the release"

# before the first signal: the session changed after the start answered
lk_setup
lk_lost
cat >"$T/on-uqmi" <<'HOOK'
#!/bin/sh
[ "$1" != start ] || printf '{"up":true,"l3_device":"wwan0","data":{"cid_4":"19","pdh_4":"1"}}\n' >/lwtest/ifstatus/wwan.json
HOOK
chmod +x "$T/on-uqmi"
lw-linkwatch once
lw_expect_eq "$(cat "$EVENTS")" "" "events: no signal after the session changed"
lk_lines | grep -qE "$CHANGED" || lw_fail "info line: $(lk_lines)"

# before the escalation: the session changes in the last nap before the 20 s are over
lk_setup
lk_lost
echo '"Call failed"' >"$T/uqmi/q-start"
LK_IFBIRTH=900
lk_netifd up
on_nap 10 "echo 1019 >/lwtest/ifbirth"
lw-linkwatch once
ended "a session that changed before the escalation"

# R49h with the escalation marker: the incident of one start escalated; the interface came up again
# with the same client and handle (another birth): its loss is a new incident, one ifup more. With
# the same birth it is still the old incident and nothing happens.
lk_setup
LK_IFBIRTH=900
lk_netifd up
lk_lost
echo '"Call failed"' >"$T/uqmi/q-start"
lw-linkwatch once
lw_expect_eq "$(ifups)" 1 "ifup events of the first incident"
lk_lost
: >"$CALLS"
lw-linkwatch once
lw_expect_eq "$(lk_calls_of --start-network)" 0 "start calls of the same start after its escalation"
lw_expect_eq "$(ifups)" 1 "ifup events of the same start after its escalation"
lw_uptime_set 1150
LK_IFBIRTH=1100
lk_netifd up
lk_lost
lw-linkwatch once
lw_expect_eq "$(lk_calls_of --start-network)" 10 "start calls of the new start, the same numbers"
lw_expect_eq "$(ifups)" 2 "ifup events after the loss in the new start"
unset LK_IFBIRTH

# a marker without a session (a respawn of an older watcher left it) does not hold a session
lk_setup
lk_lost
mkdir -p /var/run/lw-linkwatch
: >/var/run/lw-linkwatch/escalated
lw-linkwatch once
lw_expect_eq "$(lk_info)" 1 "watcher syslog lines with an old marker"
lk_lines | grep -qF "restored in place" || lw_fail "info line: $(lk_lines)"
echo ok
