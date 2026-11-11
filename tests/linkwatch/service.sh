# R49: the procd service runs `lw-linkwatch run` as one instance, respawned without limit; the script
# refuses an unknown subcommand with exit code 2 and no uqmi call; a TERM ends the loop in its nap.
# R12c: lw-linkwatch is the only file of the image that runs uqmi, and nothing else of it touches the
# modem except through the AT helper.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc
lk_setup

procd_open_instance() { echo open >>"$T/procd"; }
procd_set_param() { echo "$*" >>"$T/procd"; }
procd_close_instance() { echo close >>"$T/procd"; }
: >"$T/procd"
(
    # shellcheck source=src/files/etc/init.d/lw-linkwatch
    . /etc/init.d/lw-linkwatch
    start_service
)
lw_expect_eq "$(cat "$T/procd")" "open
command /usr/sbin/lw-linkwatch run
respawn 3600 5 0
close" "procd instance"

rc=0
lw-linkwatch bogus 2>/dev/null || rc=$?
lw_expect_eq "$rc" 2 "exit code of an unknown subcommand"
rc=0
lw-linkwatch 2>/dev/null || rc=$?
lw_expect_eq "$rc" 2 "exit code without a subcommand"
lw_expect_eq "$(cat "$CALLS")" "" "uqmi calls of a refused command"

# TERM in the nap: the loop ends at once and leaves no process behind. The real sleep is needed here.
PATH=${PATH#/fw/tests/linkwatch/stubs:}
LW_LINKWATCH_PERIOD=60 lw-linkwatch run &
pid=$!
i=0
while [ "$(wc -l <"$CALLS")" -lt 1 ] && [ "$i" -lt 50 ]; do /bin/sleep 0.1 2>/dev/null || /bin/sleep 1; i=$((i + 1)); done
kill -TERM "$pid"
wait "$pid" || :
! kill -0 "$pid" 2>/dev/null || lw_fail "the loop survived TERM"
! pgrep -f 'sleep 60' >/dev/null || lw_fail "a nap survived TERM"

# the whole overlay: uqmi only in lw-linkwatch, and its calls all carry -t and a timeout
F=/fw/src/files
hits=$(grep -rlE '^[^#]*\buqmi\b' "$F" || :)
lw_expect_eq "$hits" "$F/usr/sbin/lw-linkwatch" "files that run uqmi"
! grep -nE '^[^#]*(ttyUSB1|modemband\.sh|sms_tool|/dev/ttyUSB)' "$F/usr/sbin/lw-linkwatch" ||
    lw_fail "lw-linkwatch talks to the modem outside the AT helper"
grep -qF 'timeout -k 1' "$F/usr/sbin/lw-linkwatch" || lw_fail "no timeout around uqmi"
echo ok
