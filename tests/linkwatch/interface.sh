# R49a: when netifd takes wwan down during an incident (watchcat or a person restarted the
# interface), the watcher stops at once: no more uqmi calls, no ifup of its own, one info line.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc
lk_setup
lk_lost
echo '"Call failed"' >"$T/uqmi/q-start"
cat >"$T/on-sleep" <<'HOOK'
#!/bin/sh
n=$(cat /lwtest/naps 2>/dev/null || echo 0)
n=$((n + 1))
echo $n >/lwtest/naps
[ "$n" != 2 ] || printf '{"up":false}\n' >/lwtest/ifstatus/wwan.json
HOOK
chmod +x "$T/on-sleep"
lw-linkwatch once
lw_expect_eq "$(lk_calls_of --start-network)" 2 "start-network calls before netifd took wwan down"
lw_expect_eq "$(cat "$EVENTS")" "" "events"
lw_expect_eq "$(lk_info)" 1 "watcher syslog lines"
lk_lines | grep -qE "data session lost, netifd took wwan down after 4 s, nothing more to do\$" || lw_fail "info line: $(lk_lines)"
# and the next passes make no call while it is down
: >"$CALLS"
lw-linkwatch once
lw_expect_eq "$(cat "$CALLS")" "" "uqmi calls while wwan is down"
echo ok
