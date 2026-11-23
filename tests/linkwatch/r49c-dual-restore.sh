# R49c, R49h, D196: with both calls published and the IPv4 call lost, the restore touches the IPv4
# client only. The IPv6 client is never asked, started or stopped, the stand-in's model of the
# wildcard stop (it takes every call down) is never triggered, and no exit of the incident restarts
# wwan.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc
v6_untouched() {
    lw_expect_eq "$(cat "$T/uqmi-calls.18" 2>/dev/null)" "" "uqmi calls on the IPv6 client $1"
    lw_expect_eq "$(lk_calls_of --stop-network)" 0 "stop calls $1"
    lw_expect_eq "$(cat "$T/uqmi/session-18")" up "IPv6 call $1"
}

# the IPv4 restore leaves the IPv6 call up (R49c, R49h)
lk_setup
lk_dual
lk_lost
pid=$(cat /var/run/udhcpc-wwan0.pid)
lw-linkwatch once
v6_untouched "after the restore"
lw_expect_eq "$(cat "$EVENTS")" "kill USR2 $pid
kill USR1 $pid" "events of a dual-stack restore: the same signals, no ifup"
lw_expect_eq "$(grep -e --start-network "$CALLS")" "$START_PLAIN" "the start-network call"
lw_expect_eq "$(cat "$T/addr/wwan0")" $NEW_ADDR "address of wwan0"
lk_lines | grep -qE " lw-linkwatch: data session lost with the modem registered, restored in place after 1 s, address $OLD_ADDR -> $NEW_ADDR\$" ||
    lw_fail "info line: $(lk_lines)"

# "No effect" next to the IPv6 call: no wildcard stop, the start is retried as it is (R49c, D196)
lk_setup
lk_dual
lk_lost
printf '%s\n' '"No effect"' '"No effect"' 3203210528 >"$T/uqmi/q-start"
lw-linkwatch once
v6_untouched "after No effect"
lw_expect_eq "$(lk_calls_of --start-network)" 3 "start-network calls, retried as they are"
lw_expect_eq "$(grep -e --start-network "$CALLS" | sort -u)" "$START_PLAIN" "every start is the same call"
lk_lines | grep -qE "restored in place after 5 s," || lw_fail "info line: $(lk_lines)"

# the IPv6 client's state is unknown (a client without a handle): the same
lk_setup
lk_netifd up v4half
echo up >"$T/uqmi/session-18"
lk_lost
printf '%s\n' '"No effect"' 3203210528 >"$T/uqmi/q-start"
lw-linkwatch once
v6_untouched "with the IPv6 state unknown"
lw_expect_eq "$(lk_calls_of --start-network)" 2 "start-network calls with the IPv6 state unknown"

# the IPv6 call appears in netifd's data during the incident (R73p: the handler publishes it in a
# second update): from then on no wildcard stop either
lk_setup
lk_lost
printf '%s\n' '"No effect"' 3203210528 >"$T/uqmi/q-start"
cat >"$T/on-uqmi" <<'HOOK'
#!/bin/sh
[ "$1" != start ] || printf '{"up":true,"l3_device":"wwan0","data":{"cid_4":"17","pdh_4":"3203210528","cid_6":"18","pdh_6":"3203210529"}}\n' >/lwtest/ifstatus/wwan.json
HOOK
chmod +x "$T/on-uqmi"
lw-linkwatch once
lw_expect_eq "$(lk_calls_of --stop-network)" 0 "stop calls after the IPv6 call appeared"
lw_expect_eq "$(lk_calls_of --start-network)" 2 "start-network calls after the IPv6 call appeared"

# without an IPv6 call the clearing stop of today stays (tests/linkwatch/retry.sh), also when the
# IPv6 keys are there and empty
lk_setup
lk_lost
printf '{"up":true,"l3_device":"wwan0","data":{"cid_4":"17","pdh_4":"3203210528","cid_6":"","pdh_6":""}}\n' >"$T/ifstatus/wwan.json"
printf '%s\n' '"No effect"' 3203210528 >"$T/uqmi/q-start"
lw-linkwatch once
lw_expect_eq "$(lk_calls_of --stop-network)" 1 "stop calls with empty IPv6 values"

# R73g, R49c: the profile and the autoconnect of the original IPv4 call. Profile after the APN as in
# qmi.sh, autoconnect off only with the option 0
lk_setup
uci set network.wwan.apn=fake.apn.q7x9
uci set network.wwan.profile=3
uci commit network
lk_lost
lw-linkwatch once
lw_expect_eq "$(grep -e --start-network "$CALLS")" \
    "-s -d /tmp/cdc-wdm0 -t 5000 --set-client-id wds,17 --start-network --apn fake.apn.q7x9 --profile 3 --autoconnect" \
    "start with a profile"
lk_setup
uci set network.wwan.autoconnect=0
uci commit network
lk_lost
lw-linkwatch once
lw_expect_eq "$(grep -e --start-network "$CALLS")" \
    "-s -d /tmp/cdc-wdm0 -t 5000 --set-client-id wds,17 --start-network" "start with autoconnect 0"
lk_setup
uci set network.wwan.autoconnect=1
uci commit network
lk_lost
lw-linkwatch once
lw_expect_eq "$(grep -e --start-network "$CALLS")" "$START_PLAIN" "start with autoconnect 1"
echo ok
