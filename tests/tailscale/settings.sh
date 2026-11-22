# R64, D154: the settings hold at every start, as soon as the daemon answers and before anyone signs
# in, and again after a sign-in; without Telegram keys and SMS admins (nothing of them is set here).
# shellcheck source=tests/tailscale/ts.inc
. /fw/tests/tailscale/ts.inc
ts_setup
EXPECT="set $SET_ARGS --advertise-routes= --hostname=lw-test-rtr"

# the daemon is not up: nothing is set, and the service does not give up
ts_once
lw_expect_eq "$(ts_count set)" 0 "set calls without a daemon"

# it answers (a fresh router, no sign-in): set once, however many passes follow
ts_backend NeedsLogin
LW_TS_PASSES=3 lw-tailscale run
lw_expect_eq "$(ts_calls)" "$EXPECT" "the settings of a fresh router"

# a restart of the service (or of the router) sets them again
ts_reboot
ts_once
lw_expect_eq "$(ts_count set)" 2 "set calls after a restart"

# the daemon crashes and comes back during one run: set again when it answers
ts_down
rm -f "$D/calls"
ts_backend NeedsLogin
echo 0 >"$T/step"
ts_hook 'n=$(cat /lwtest/step); echo $((n + 1)) >/lwtest/step
[ "$n" != 1 ] || rm -f /lwtest/ts/backend
[ "$n" != 2 ] || echo NeedsLogin >/lwtest/ts/backend'
LW_TS_PASSES=5 lw-tailscale run
lw_expect_eq "$(ts_count set)" 2 "set calls over a crash of the daemon"
rm -f "$T/on-sleep"

# a sign-in: the settings are set again once the router is added, and not at every pass after it
rm -f "$D/calls"
ts_reboot
ts_backend NeedsLogin
echo 0 >"$T/step"
ts_hook 'n=$(cat /lwtest/step); echo $((n + 1)) >/lwtest/step
[ "$n" != 0 ] || echo Running >/lwtest/ts/backend'
LW_TS_PASSES=4 lw-tailscale run
lw_expect_eq "$(ts_count set)" 2 "set calls around a sign-in"
lw_expect_eq "$(ts_calls | sort -u)" "$EXPECT" "the same settings after the sign-in"
rm -f "$T/on-sleep"

# the LAN prefix is offered with advertise_lan=1 and only then (R67)
uci set lonewrt.tailscale.advertise_lan=1
uci commit lonewrt
rm -f "$D/calls"
ts_reboot
ts_once
lw_expect_eq "$(ts_calls)" "set $SET_ARGS --advertise-routes=192.168.5.0/24 --hostname=lw-test-rtr" \
    "the settings with the LAN offered"

# a failed set is tried again at the next pass
touch "$D/set-fail"
rm -f "$D/calls"
ts_reboot
LW_TS_PASSES=3 lw-tailscale run
lw_expect_eq "$(ts_count set)" 3 "set calls while set fails"
rm -f "$D/set-fail"
LW_TS_PASSES=3 lw-tailscale run
lw_expect_eq "$(ts_count set)" 4 "set calls once it works"
echo ok
