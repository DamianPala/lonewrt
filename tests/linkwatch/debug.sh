# R29c, R49g: at the info level an incident writes its one info line and no debug line. At the debug
# level every step of the incident is logged at daemon.debug with its time since the loss, and after
# the restore, never before it, a snapshot of the modem over AT through the image's helper and lock,
# five commands, nothing else on the port. The snapshot stops at the first command that does not
# answer in time.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc

# info level
lk_setup
lk_lost
lw-linkwatch once
lw_expect_eq "$(lk_info)" 1 "watcher syslog lines at the info level"
lw_expect_eq "$(lk_debug_lines)" "" "debug lines at the info level"
lw_expect_eq "$(cat "$T/at-calls" 2>/dev/null)" "" "AT commands at the info level"

# debug level
lk_setup
uci set lonewrt.log=log
uci set lonewrt.log.level=debug
uci commit lonewrt
lw_at_override 'AT+CEER' '+CEER: Nas detach with reattach, LTE network detach'
lw_at_override 'AT+CEREG?' '+CEREG: 0,1'
lw_at_override 'AT+CGATT?' '+CGATT: 1'
lw_at_override 'AT+CGACT?' '+CGACT: 1,1'
lw_at_override 'AT+CGPADDR=1' '+CGPADDR: 1,"10.4.5.6"'
: >"$T/at-calls"
lk_lost
lw-linkwatch once
lw_expect_eq "$(grep -c 'daemon.notice lw-linkwatch:' "$T/syslog.prio")" 1 "info lines at the debug level"
steps=$(lk_debug_lines)
for want in "+0s lost: data status disconnected, settings Out of call, device wwan0, address $OLD_ADDR, client 17, handle 3203210528" \
    "+0s start-network gave handle 3203210528"; do
    printf '%s\n' "$steps" | grep -qF "lw-linkwatch: $want" || lw_fail "no debug step '$want' in: $steps"
done
printf '%s\n' "$steps" | grep -qE 'lw-linkwatch: \+0s udhcpc [0-9]+ released and asked for a new lease' ||
    lw_fail "no udhcpc step in: $steps"
printf '%s\n' "$steps" | grep -qE 'lw-linkwatch: \+1s ' || lw_fail "no step with a later time: $steps"
lw_expect_eq "$(tr '\n' ';' <"$T/at-calls")" \
    "/dev/ttyUSB2 at AT+CEER;/dev/ttyUSB2 at AT+CEREG?;/dev/ttyUSB2 at AT+CGATT?;/dev/ttyUSB2 at AT+CGACT?;/dev/ttyUSB2 at AT+CGPADDR=1;" \
    "AT commands of the snapshot"
printf '%s\n' "$steps" | grep -qF 'AT snapshot AT+CEER: +CEER: Nas detach with reattach, LTE network detach' ||
    lw_fail "no CEER line: $steps"
printf '%s\n' "$steps" | grep -qF 'AT snapshot AT+CGPADDR=1: +CGPADDR: 1,"10.4.5.6"' || lw_fail "no CGPADDR line: $steps"
# order: the outcome line, then the snapshot
lw_expect_eq "$(grep -n 'daemon.notice lw-linkwatch:' "$T/syslog.prio" | cut -d: -f1)" \
    "$(($(grep -n 'AT snapshot AT+CEER' "$T/syslog.prio" | cut -d: -f1) - 1))" "line before the snapshot"
lw_expect_eq "$(grep -c 'AT snapshot' "$T/syslog.prio")" 5 "snapshot lines"

# a snapshot that hangs stops at the first command and does not ask for the rest
lk_setup
uci set lonewrt.log=log
uci set lonewrt.log.level=debug
uci commit lonewrt
lw_at_override 'AT+CEREG?' HANG
: >"$T/at-calls"
lk_lost
LW_LINKWATCH_AT_LIMIT=1 lw-linkwatch once
lw_expect_eq "$(lk_info)" "$(($(lk_debug_lines | wc -l) + 1))" "every watcher line is the info one or a debug one"
lk_debug_lines | grep -qF 'AT snapshot stopped at AT+CEREG?: no answer within 1 s' || lw_fail "no stop line: $(lk_debug_lines)"
! grep -q 'AT+CGATT' "$T/at-calls" || lw_fail "a command after the one that hung"
echo ok
