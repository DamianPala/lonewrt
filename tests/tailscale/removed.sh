# R68b, D161: a request for the link (`lw-tailscale link`, behind /tailscale, its button and the SMS
# `tailscale`) of a router that counts as added while Tailscale shows it offline restarts Tailscale at
# most once per 10 minutes and answers from the state after the restart, inside the 25 s of R65a.
# shellcheck source=tests/tailscale/ts.inc
. /fw/tests/tailscale/ts.inc
ts_setup
URL=https://login.example.invalid/a/FAKELINK01
STAMP=/tmp/lw-tailscale/restart-at

now_s() { cut -d. -f1 "$T/uptime"; }
ts_init() {
    mkdir -p /etc/init.d
    cp /fw/tests/tailscale/stubs/init-tailscale /etc/init.d/tailscale
}
ts_restarts() { if [ -f "$D/init-calls" ]; then grep -c '^restart$' "$D/init-calls" || :; else echo 0; fi; }
LOG=/tmp/lw-signal.log
# ts_net LOSS: the newest line of the signal log (R28), the router's own reading of the internet
ts_net() {
    printf '2026-11-23_10:00:00 zsnt=6 net=LTE pb=B3 s1=? rsrp=-90dBm rsrq=-10dB sinr=12dB rssi=-60dBm pci=1 loss=%s rtt=40 wg_age=?\n' \
        "$1" >"$LOG"
}
# ts_removed: an added router, signed in as far as the service knows, that Tailscale shows offline,
# while the router reaches the internet (R68b)
ts_removed() {
    ts_added $((BASE + 100 * 86400))
    ts_once
    : >"$D/offline"
    echo url >"$D/up-mode"
    ts_net 0%
}
# the stand-in restart ends in the background, and the test clock does not wait: a nap while a restart
# was started and has not marked its end waits a real second (not for a held one, which the test ends)
# shellcheck disable=SC2016  # the hook script expands $LW_TEST when it runs
ts_hook '[ -e /tmp/lw-tailscale/restart-at ] && [ ! -e /tmp/lw-tailscale/restart-done ] &&
    [ ! -e "$LW_TEST/ts/restart-hold" ] && /bin/sleep 1; exit 0'
ts_init

# added and online: no restart, the state as before (exit 2)
ts_added $((BASE + 100 * 86400))
ts_once
rc=0
out=$(lw-tailscale link) || rc=$?
lw_expect_eq "$rc" 2 "exit code of an added, online router"
lw_expect_eq "$(ts_restarts)" 0 "restarts of an added, online router"
[ ! -e "$STAMP" ] || lw_fail "a restart time was kept without a restart"

# removed in the admin page: one restart, then the link, exit 0, the state ended and expired due
ts_world
ts_removed
t0=$(now_s)
rc=0
out=$(lw-tailscale link 2>"$T/err") || rc=$?
lw_expect_eq "$rc" 0 "exit code of a removed router"
lw_expect_eq "$out" "$URL" "the link of a removed router"
lw_expect_eq "$(cat "$T/err")" "" "stderr of link"
lw_expect_eq "$(ts_restarts)" 1 "restarts of a removed router"
lw_expect_eq "$(ts_st state)" ended "state file after the restart"
lw_expect_eq "$(ts_due)" expired "due after the restart"
[ $(($(now_s) - t0)) -le 25 ] || lw_fail "link took more than 25 s"
lw_expect_no_grep "$T/syslog" "http"
lw_expect_no_grep "$T/syslog" "FAKELINK"
# the loop's own pass after it does not repeat the message once it went
lw-tailscale mark expired
ts_once
lw_expect_eq "$(ts_due)" "" "due after the mark and a pass of the loop"

# a second request within 10 minutes does not restart again: the state as it stands (exit 2)
ts_added $((BASE + 100 * 86400))
: >"$D/offline"
lw_uptime_add 590
rc=0
out=$(lw-tailscale link) || rc=$?
lw_expect_eq "$rc" 2 "exit code within 10 minutes of the last restart"
lw_expect_eq "$(ts_restarts)" 1 "restarts within 10 minutes"
case $out in *state=added*) ;; *) lw_fail "no state in '$out'" ;; esac
# after the 10 minutes it restarts again
lw_uptime_add 12
rc=0
out=$(lw-tailscale link) || rc=$?
lw_expect_eq "$rc$out" "0$URL" "link 10 minutes after the last restart"
lw_expect_eq "$(ts_restarts)" 2 "restarts after 10 minutes"

# a reboot clears the time of the last restart (it lives in RAM)
ts_added $((BASE + 100 * 86400))
: >"$D/offline"
lw_uptime_add 5
rc=0
lw-tailscale link >/dev/null || rc=$?
lw_expect_eq "$rc" 2 "exit code right after a restart"
lw_expect_eq "$(ts_restarts)" 2 "restarts right after a restart"
ts_reboot
ts_init
ts_net 0%
rc=0
lw-tailscale link >/dev/null || rc=$?
lw_expect_eq "$(ts_restarts)" 3 "restarts after a reboot"

# still added and offline after the restart: exit 2 with the state, no link, no call of up
ts_world
ts_init
ts_removed
echo Running >"$D/restart-to"
rc=0
out=$(lw-tailscale link) || rc=$?
lw_expect_eq "$rc" 2 "exit code of a router still added after the restart"
case $out in *state=added*) ;; *) lw_fail "no state in '$out'" ;; esac
case $out in *http*) lw_fail "a link for a router still added" ;; esac
lw_expect_eq "$(ts_restarts)" 1 "restarts of a router that stays added"
lw_expect_eq "$(ts_count up)" 0 "up calls for a router that stays added"
lw_expect_eq "$(ts_st state)" added "state file of a router that stays added"

# Running and still offline right after the restart (the old daemon may answer for a moment): the
# wait goes on, and at its end the router counts as added (exit 2), inside the 25 s
ts_world
ts_init
ts_removed
echo Running >"$D/restart-to"
: >"$D/restart-offline"
t0=$(now_s)
rc=0
out=$(lw-tailscale link) || rc=$?
lw_expect_eq "$rc" 2 "exit code of a router still offline after the restart"
[ $(($(now_s) - t0)) -ge 5 ] || lw_fail "an offline Running right after the restart ended the wait"
[ $(($(now_s) - t0)) -le 25 ] || lw_fail "a restart that stays offline took more than 25 s"
lw_expect_eq "$(ts_restarts)" 1 "restarts of a router that stays offline"

# a restart that does not settle in time: exit 3 with the state starting, inside the 25 s
ts_world
ts_init
ts_removed
echo Starting >"$D/restart-to"
t0=$(now_s)
rc=0
out=$(lw-tailscale link) || rc=$?
lw_expect_eq "$rc$out" "3state=starting" "a restart that does not settle"
[ $(($(now_s) - t0)) -le 25 ] || lw_fail "an unsettled restart took more than 25 s"
lw_expect_eq "$(ts_restarts)" 1 "restarts that do not settle"
lw_expect_eq "$(ts_count up)" 0 "up calls while starting"

# a restart that is still going on at the end of the budget is not cut short: exit 3 within 25 s, the
# restart goes on, and once it is done one pass of the service shows the sign-in ended (R68b)
ts_world
ts_init
ts_removed
: >"$D/restart-hold"
t0=$(now_s)
rc=0
# called as the bot's queue flush calls it, with its lock on fd 8: the lock is free once link returns
out=$( (
    flock -n 8 || exit 9
    lw-tailscale link
) 8>"$T/queue.lock") || rc=$?
lw_expect_eq "$rc$out" "3state=starting" "a restart that is not done"
flock -n "$T/queue.lock" true || lw_fail "the restart that goes on holds the caller's lock"
[ $(($(now_s) - t0)) -le 25 ] || lw_fail "a restart that is not done took more than 25 s"
lw_expect_eq "$(ts_restarts)" 1 "restarts that are not done"
lw_expect_eq "$(ts_count up)" 0 "up calls while the restart is not done"
lw_expect_eq "$(ts_st state)" added "state file left to the loop"
pgrep -f 'init.d/tailscale restart' >/dev/null || lw_fail "the restart was cut short"
[ ! -e /tmp/lw-tailscale/restart-done ] || lw_fail "restart-done before the restart ended"
: >"$D/restart-release"
i=0
until [ -e /tmp/lw-tailscale/restart-done ]; do
    /bin/sleep 1
    i=$((i + 1))
    [ "$i" -lt 15 ] || lw_fail "the restart did not end"
done
ts_once
lw_expect_eq "$(ts_st state)" ended "state after the restart ended"
lw_expect_eq "$(ts_due)" expired "due after the restart ended"
lw_expect_eq "$(ts_restarts)" 1 "restarts in all"

# the router does not reach the internet (no line of the signal log, a line without a reading or
# with all packets lost): no restart, the state as it stands (exit 2)
for net in none '?' 100%; do
    ts_world
    ts_init
    ts_removed
    if [ "$net" = none ]; then rm -f "$LOG"; else ts_net "$net"; fi
    rc=0
    out=$(lw-tailscale link) || rc=$?
    lw_expect_eq "$rc" 2 "exit code of an offline router without internet ($net)"
    case $out in *state=added*) ;; *) lw_fail "no state in '$out' ($net)" ;; esac
    lw_expect_eq "$(ts_restarts)" 0 "restarts without internet ($net)"
    [ ! -e "$STAMP" ] || lw_fail "a restart time was kept without a restart ($net)"
done
# a line with some packets lost still counts as internet
ts_world
ts_init
ts_removed
ts_net 33%
rc=0
out=$(lw-tailscale link) || rc=$?
lw_expect_eq "$rc$out" "0$URL" "link with 33% packet loss"

# an ended router (the service saw the removal itself) gets its link without a restart, as before
ts_world
ts_init
ts_added $((BASE + 100 * 86400))
ts_once
ts_backend NeedsLogin
echo url >"$D/up-mode"
rc=0
out=$(lw-tailscale link) || rc=$?
lw_expect_eq "$rc$out" "0$URL" "link of an ended router"
lw_expect_eq "$(ts_restarts)" 0 "restarts of an ended router"
echo ok
