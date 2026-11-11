# R49b, R49c, R49f: the session is lost with the modem registered (data status disconnected, settings
# Out of call): the call is started again on netifd's client with the exact call that qmi.sh makes,
# udhcpc gets USR2 and, once the release is done, USR1, the device has the modem's new address, no `ifup`, one info line;
# the next pass is healthy and silent.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc
lk_setup
lk_lost
pid=$(cat /var/run/udhcpc-wwan0.pid)

lw-linkwatch once

lw_expect_eq "$(lk_calls_of --start-network)" 1 "start-network calls"
lw_expect_eq "$(grep -e --start-network "$CALLS")" "$START_PLAIN" "the start-network call"
lw_expect_eq "$(grep -c -e '--set-client-id wds,17' "$CALLS")" "$(grep -c -e '--set-client-id' "$CALLS")" \
    "calls on netifd's client"
lw_expect_eq "$(cat "$EVENTS")" "kill USR2 $pid
kill USR1 $pid" "events: USR2 then USR1 to the pid of netifd's udhcpc, no ifup"
lw_expect_eq "$(cat /lwtest/addr/wwan0)" $NEW_ADDR "address of wwan0"
lw_expect_eq "$(lk_info)" 1 "watcher syslog lines"
lk_lines | grep -qE " lw-linkwatch: data session lost with the modem registered, restored in place after 1 s, address $OLD_ADDR -> $NEW_ADDR\$" ||
    lw_fail "info line: $(lk_lines)"
[ ! -e "$T/syslog.prio" ] || ! grep -q 'daemon.debug' "$T/syslog.prio" || lw_fail "a debug line at the info level"
lw_expect_eq "$(cat "$T/sleeps")" "sleep 1" "naps of the incident"

# the next pass: healthy, one call, nothing written
: >"$CALLS"
lw-linkwatch once
lw_expect_eq "$(wc -l <"$CALLS" | tr -d ' ')" 1 "calls of the pass after the restore"
lw_expect_eq "$(lk_info)" 1 "watcher syslog lines after a healthy pass"
echo ok
