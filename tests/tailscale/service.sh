# R63c, R64, D135: the procd service starts after the package's init (START=80), as one instance
# that is respawned without limit, and needs neither Telegram nor SMS admins; the script refuses an
# unknown subcommand; a TERM ends the loop in its nap.
# shellcheck source=tests/tailscale/ts.inc
. /fw/tests/tailscale/ts.inc
ts_setup

procd_open_instance() { echo open >>"$T/procd"; }
procd_set_param() { echo "$*" >>"$T/procd"; }
procd_close_instance() { echo close >>"$T/procd"; }
: >"$T/procd"
(
    # shellcheck source=src/files/etc/init.d/lw-tailscale
    . /etc/init.d/lw-tailscale
    start_service
    lw_expect_eq "$START" 81 "start order (after the package's init at 80)"
)
lw_expect_eq "$(cat "$T/procd")" "open
command /usr/sbin/lw-tailscale run
respawn 3600 5 0
close" "procd instance"
# nothing of the notification keys is read: the instance starts with none set
lw_expect_eq "$(uci -q get lonewrt.notify.token)$(uci -q get lonewrt.notify.sms_admins)" "" "notify keys"
[ -x /etc/init.d/lw-tailscale ] || lw_fail "the init script is not executable"
[ -x /usr/sbin/lw-tailscale ] || lw_fail "lw-tailscale is not executable"

rc=0
lw-tailscale bogus 2>/dev/null || rc=$?
lw_expect_eq "$rc" 2 "exit code of an unknown subcommand"
rc=0
lw-tailscale 2>/dev/null || rc=$?
lw_expect_eq "$rc" 2 "exit code without a subcommand"
lw_expect_eq "$(ts_calls)" "" "tailscale calls of a refused command"
rc=0
lw-tailscale mark 2>/dev/null || rc=$?
lw_expect_eq "$rc" 1 "mark without an event"

# TERM in the nap: the loop ends at once and leaves no process behind. The real sleep is needed here.
ts_backend NeedsLogin
PATH=/fw/tests/tailscale/stubs:${PATH#/fw/tests/tailscale/stubs:/fw/tests/tailscale/clock:}
LW_TS_PERIOD=60 lw-tailscale run &
pid=$!
i=0
while [ ! -f /tmp/lw-tailscale/state ] && [ "$i" -lt 50 ]; do /bin/sleep 0.1 2>/dev/null || /bin/sleep 1; i=$((i + 1)); done
[ -f /tmp/lw-tailscale/state ] || lw_fail "the loop wrote no state file"
kill -TERM "$pid"
wait "$pid" || :
! kill -0 "$pid" 2>/dev/null || lw_fail "the loop survived TERM"
! pgrep -f 'sleep 60' >/dev/null || lw_fail "a nap survived TERM"
echo ok
