# R74f, R74c: a change of the LAN's IPv6 that did not reach odhcpd (the mark lan6.sh keeps) is finished by
# the next cron run too, last, after everything the ladder decides; a router without the mark runs and
# reads nothing for it (one builtin test), and a failing reload changes nothing of the ladder.
# shellcheck source=tests/ladder/ladder.inc
. /fw/tests/ladder/ladder.inc

LW_LAN6_INIT=/fw/tests/linkwatch/stubs/lan6-init
LW_LAN6_PENDING=$T/pending
export LW_LAN6_INIT LW_LAN6_PENDING
CALLS=$T/lan6-calls
lw_net up down
lw_dns up down
lw_session v4

: >"$CALLS"
runs 1
lw_expect_eq "$(cat "$CALLS")" "" "R74f no mark: no reload from the ladder"

echo off >"$LW_LAN6_PENDING"
runs 1
lw_expect_eq "$(cat "$CALLS")" "reload lan6 flag=none" "R74f pending mark: one reload"
: >"$CALLS"
DRYRUN=1 "$WR" >/dev/null 2>&1 || lw_fail "dry run failed"
lw_expect_eq "$(cat "$CALLS")" "" "R74f a dry run reloads nothing"
: >"$T/lan6-fail"
runs 1
lw_expect_eq "$(wc -l <"$CALLS" | tr -d ' ')" 1 "R74f a failing reload is only attempted"
echo ok
