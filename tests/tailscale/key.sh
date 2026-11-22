# R64b, R66a, R66b, D141, D145: the auth key signs a fresh router in once. It counts as used when
# Tailscale answered, accepted or refused, and the record of that comes before the refusal can be
# reported; with no answer (no internet) the key is tried again; a used key is never tried again.
# shellcheck source=tests/tailscale/ts.inc
. /fw/tests/tailscale/ts.inc
ts_setup
UP="up --auth-key=file:$KEY --timeout=25s $SET_ARGS --advertise-routes= --hostname=lw-test-rtr"

# no key file, no key attempt
ts_backend NeedsLogin
echo accept >"$D/up-mode"
ts_once
lw_expect_eq "$(ts_count up)" 0 "up calls without a key file"

# accepted: the call carries the key as a file and the settings of R64, the router is added, the key
# is used and its file is gone, and the bot is owed the added message, not a link
ts_key
ts_once
lw_expect_eq "$(grep '^up ' "$D/calls")" "$UP" "the call of the key"
lw_expect_eq "$(ts_st state)" added "state after an accepted key"
lw_expect_eq "$(cat "$SENT/key-used")" accepted "record of an accepted key"
[ ! -e "$KEY" ] || lw_fail "the key file stays after the key is used"
lw_expect_eq "$(ts_due)" added "messages due after an accepted key"
lw_expect_eq "$(ts_count set)" 2 "set once per start, before the key is tried"
for f in "$T/syslog" /tmp/lw-tailscale/state "$D/calls" "$SENT"/*; do
    lw_expect_no_grep "$f" "FAKEKEY"
done
[ ! -e /tmp/lw-tailscale/up.out ] || lw_fail "the output of up stays in RAM"

# refused: used, file gone, the refusal due and no link message; a restart does not try again, and
# the refusal is due once
ts_world
ts_key
ts_backend NeedsLogin
echo refuse >"$D/up-mode"
ts_once
lw_expect_eq "$(ts_count up)" 1 "up calls with a refused key"
lw_expect_eq "$(ts_st state)" not_added "state after a refused key"
lw_expect_eq "$(cat "$SENT/key-used")" refused "record of a refused key"
[ ! -e "$KEY" ] || lw_fail "the key file stays after a refusal"
lw_expect_eq "$(ts_due)" refused "messages due after a refused key"
for f in "$T/syslog" /tmp/lw-tailscale/state "$SENT"/*; do
    lw_expect_no_grep "$f" "FAKEKEY"
done
ts_reboot
ts_once
ts_once
lw_expect_eq "$(ts_count up)" 1 "up calls after restarts"
lw_expect_eq "$(ts_due)" refused "refusal still due after a restart"
lw-tailscale mark refused
lw_expect_eq "$(ts_due)" "" "messages due after the refusal went"
ts_reboot
ts_once
lw_expect_eq "$(ts_due)" "" "messages due after a restart (no link message after a refusal, R65)"
# a key file put back (a flash that keeps settings and writes it again) is not tried
ts_key
ts_once
lw_expect_eq "$(ts_count up)" 1 "a used key is not tried again"

# no internet: no answer, nothing recorded, a new try after the pause and at a restart
ts_world
ts_key
ts_backend NeedsLogin
echo noanswer >"$D/up-mode"
ts_once
lw_expect_eq "$(ts_count up)" 1 "first try without internet"
[ ! -e "$SENT/key-used" ] || lw_fail "a key without an answer is recorded as used"
[ -e "$KEY" ] || lw_fail "the key file goes without an answer"
lw_expect_eq "$(ts_due)" "" "messages due while the key waits for the internet"
lw_expect_eq "$(ts_st state)" not_added "state while the key waits"
ts_reboot
ts_once
lw_expect_eq "$(ts_count up)" 2 "a restart tries again"
# the pause: passes 30 s apart, the key tried every 60 s; the internet is back before the third pass
ts_hook 'n=$(cat /lwtest/step 2>/dev/null || echo 0); echo $((n + 1)) >/lwtest/step
[ "$n" != 1 ] || echo accept >/lwtest/ts/up-mode'
echo 0 >"$T/step"
ts_reboot
LW_TS_PASSES=3 lw-tailscale run
lw_expect_eq "$(ts_count up)" 4 "tries over three passes (first, none, second)"
lw_expect_eq "$(ts_st state)" added "added when the internet is back"
lw_expect_eq "$(ts_due)" added "added message, no link message"
lw_expect_eq "$(cat "$SENT/key-used")" accepted "record after the late answer"
rm -f "$T/on-sleep"

# the router was added by a link first: the key is not used any more and its file goes
ts_world
ts_key
ts_added
echo accept >"$D/up-mode"
ts_once
lw_expect_eq "$(ts_count up)" 0 "up calls for a router added without the key"
[ ! -e "$KEY" ] || lw_fail "an unused key stays on an added router"
[ ! -e "$SENT/key-used" ] || lw_fail "key recorded as used though it was not"

# an ended router (signed in before, now asks for a login) is not fresh: no key
ts_world
ts_added
ts_once
ts_key
ts_backend NeedsLogin
ts_once
lw_expect_eq "$(ts_st state)" ended "state of an ended router"
lw_expect_eq "$(ts_count up)" 0 "a key is not tried on an ended router"
echo ok
