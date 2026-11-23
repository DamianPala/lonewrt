# R49a, R49b, D177: the watcher decides by the session netifd shows, before it polls. Without a
# native IPv4 call in netifd's data (an IPv6-only session, a client without a numeric handle) it
# makes no uqmi call, sends no signal and writes no line, whatever the modem would say and
# whatever the PDP type is. With one, every status and settings read is on that client. A static
# IPv4 address (dhcp 0) has no lease to renew: no signal to udhcpc.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc

# R49a: an IPv6-only session, lost or healthy, three passes: nothing at all
for t in ipv6 ipv4v6 ipv4; do
    lk_setup
    uci set network.wwan.pdptype=$t
    uci commit network
    lk_netifd up v6
    echo up >"$T/uqmi/session-18"
    lk_lost
    for i in 1 2 3; do lw-linkwatch once; done
    lk_expect_quiet "in an IPv6-only session with pdptype $t"
    lk_healthy
    lw-linkwatch once
    lk_expect_quiet "in a healthy IPv6-only session with pdptype $t"
done

# R49a: a client without a numeric handle is no native IPv4 call
for data in '"cid_4":"17"' '"cid_4":"17","pdh_4":"none"' '"pdh_4":"3203210528"' '"cid_4":"x","pdh_4":"1"'; do
    lk_setup
    lk_lost
    printf '{"up":true,"l3_device":"wwan0","data":{%s}}\n' "$data" >"$T/ifstatus/wwan.json"
    lw-linkwatch once
    lk_expect_quiet "with the data $data"
done

# R49b: the IPv4 session of the owner, with auto configured: every read is on client 17, the
# restore is the one of today, and the debug lines of the old gate are gone
lk_setup
uci set network.wwan.pdptype=ipv4v6
uci commit network
lk_lost
pid=$(cat /var/run/udhcpc-wwan0.pid)
lw-linkwatch once
lw_expect_eq "$(grep -e '--get-data-status' -e '--get-current-settings' -e '--start-network' "$CALLS" |
    grep -vc -e '--set-client-id wds,17' || true)" 0 "status, settings and start calls not on netifd's IPv4 client"
lw_expect_eq "$(grep -c -e '--get-data-status' "$CALLS")" 3 "data status reads: the pass, the step, the check after the restart"
lw_expect_eq "$(grep -c -e '--get-serving-system' "$CALLS")" 1 "registration reads"
lw_expect_eq "$(cat "$EVENTS")" "kill USR2 $pid
kill USR1 $pid" "events"
lw_expect_eq "$(lk_info)" 1 "watcher syslog lines"

# R73p: static IPv4, the address of the call comes back: restored with no signal to udhcpc
lk_setup
uci set network.wwan.dhcp=0
uci commit network
lk_lost
echo $OLD_ADDR >"$T/uqmi/newaddr"
lw-linkwatch once
lw_expect_eq "$(lk_calls_of --start-network)" 1 "start-network calls with a static address"
lw_expect_eq "$(cat "$EVENTS")" "" "events with a static address: no signal, no ifup"
lk_lines | grep -qE "restored in place after 1 s, address $OLD_ADDR -> $OLD_ADDR\$" || lw_fail "info line: $(lk_lines)"

# R73p: static IPv4 and another address from the call: nothing can renew it, so after 20 s the one
# ifup, still without a signal to udhcpc
lk_setup
uci set network.wwan.dhcp=0
uci commit network
lk_lost
lw-linkwatch once
lw_expect_eq "$(cat "$EVENTS")" "ifup wwan" "events with a static address that does not match"

# dhcp 1 is the default of the image: the signals of today
lk_setup
uci set network.wwan.dhcp=1
uci commit network
lk_lost
lw-linkwatch once
lw_expect_eq "$(grep -c '^kill' "$EVENTS")" 2 "signals with dhcp 1"
echo ok
