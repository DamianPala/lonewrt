# R49c: a start-network that fails is tried again every 2 s; one that fails twice and then works
# restores the session, with one info line. After "No effect" the client is cleared the way qmi.sh
# does before the next try. A modem that is not registered yet is waited for, with no start-network.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc

# failing twice, then working
lk_setup
lk_lost
printf '%s\n' '"Call failed"' '"Call failed"' 3203210528 >"$T/uqmi/q-start"
lw-linkwatch once
lw_expect_eq "$(lk_calls_of --start-network)" 3 "start-network calls"
lw_expect_eq "$(lk_calls_of --stop-network)" 0 "clearing calls after a plain failure"
lw_expect_eq "$(cat "$T/sleeps")" "sleep 2
sleep 2
sleep 1" "naps: 2 s between the tries, 1 s after the start"
lw_expect_eq "$(lk_info)" 1 "watcher syslog lines"
lk_lines | grep -qE "restored in place after 5 s, address $OLD_ADDR -> $NEW_ADDR\$" || lw_fail "info line: $(lk_lines)"
lw_expect_eq "$(grep -c '^kill USR2' "$EVENTS")" 1 "USR2 only after the successful start"

# "No effect", then the clearing call, then the start
lk_setup
lk_lost
printf '%s\n' '"No effect"' 3203210528 >"$T/uqmi/q-start"
lw-linkwatch once
lw_expect_eq "$(grep -e '--start-network' -e '--stop-network' "$CALLS")" "$START_PLAIN
$CLEAR_CALL
$START_PLAIN" "start, clear, start"
lk_lines | grep -qE "restored in place after 3 s," || lw_fail "info line: $(lk_lines)"

# an empty answer and garbage are retried without the clearing call
lk_setup
lk_lost
printf '%s\n' @EMPTY 'garbage' 3203210528 >"$T/uqmi/q-start"
lw-linkwatch once
lw_expect_eq "$(lk_calls_of --start-network)" 3 "start-network calls after an empty answer and garbage"
lw_expect_eq "$(lk_calls_of --stop-network)" 0 "clearing calls after an empty answer and garbage"
lw_expect_eq "$(lk_info)" 1 "watcher syslog lines after retries"

# not registered at first: no start-network until it is
lk_setup
lk_lost
echo searching >"$T/uqmi/reg"
cat >"$T/on-sleep" <<'HOOK'
#!/bin/sh
n=$(cat /lwtest/naps 2>/dev/null || echo 0)
n=$((n + 1))
echo $n >/lwtest/naps
[ "$n" -lt 3 ] || echo registered >/lwtest/uqmi/reg
HOOK
chmod +x "$T/on-sleep"
lw-linkwatch once
lw_expect_eq "$(head -n 3 "$T/sleeps" | tr '\n' ' ')" "sleep 2 sleep 2 sleep 2 " "naps while unregistered"
lw_expect_eq "$(lk_calls_of --start-network)" 1 "start-network calls: only after the registration"
lw_expect_eq "$(lk_info)" 1 "watcher syslog lines"
lk_lines | grep -qE "data session lost, modem was not registered at first, restored in place after 7 s," ||
    lw_fail "info line: $(lk_lines)"
echo ok
