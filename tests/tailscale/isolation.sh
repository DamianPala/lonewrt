# R63e, D157: no failure of Tailscale (no internet, a crash of the daemon every minute, a refused key,
# a hung CLI) restarts the router, changes the modem or wwan, or delays the link repair (R14 to R21);
# the service and wwan-recover do not look at each other. The scenario of R63e: the daemon killed
# every minute for an hour with working LTE gives no offline cycle and no restart.
# shellcheck source=tests/ladder/ladder.inc
. /fw/tests/ladder/ladder.inc
# shellcheck source=tests/tailscale/ts.inc
. /fw/tests/tailscale/ts.inc
# shellcheck source=src/files/usr/lib/lw/common.sh
. /usr/lib/lw/common.sh
ts_world

# the code: no call into the modem, netifd, the link repair or the reboot path
for f in /usr/sbin/lw-tailscale /etc/init.d/lw-tailscale; do
    hits=$(grep -nE '^[^#]*(ifup|ifdown|ifstatus|reboot|uqmi|sms_tool|lw_at|ttyUSB|cdc-wdm|lw-at\.lock|wwan|netifd|wwan-recover|lw-linkwatch|lw-fallback|lw-notify|/etc/config/network)' "$f" || :)
    lw_expect_eq "$hits" "" "calls into other parts of the router in $f"
done

# the world: working LTE, a key that is never accepted, the daemon killed and back every minute
lw_net up down
lw_dns up down
ts_key
ts_backend NeedsLogin
echo noanswer >"$D/up-mode"
: >"$T/events"
i=0
while [ "$i" -lt 12 ]; do
    ts_backend NeedsLogin
    lw-tailscale once
    ts_down
    lw-tailscale once
    ts_backend NeedsLogin
    runs 1
    i=$((i + 1))
done
lw_expect_eq "$(reboot_runs)" "" "restarts of the router"
lw_expect_eq "$(cat "$T/events")" "" "ifup, ifdown or reboot calls"
[ ! -e "$STATE" ] || lw_fail "wwan-recover state written while LTE works"
lw_expect_eq "$(grep -c 'wwan-recover: ' "$T/syslog" || :)" 0 "wwan-recover lines"
lw_expect_eq "$(lw_at 5 'AT+ZSNT?')" "+ZSNT: 6,0,0" "modem mode"
lw_expect_eq "$(mode_now)" lte "mode of wwan-recover"

# a hung CLI: the service sits in its call (the call limit ends it later), and the next wwan-recover
# run neither waits for it nor takes its lock
touch "$D/hang"
LW_TS_CALL_LIMIT=30 lw-tailscale once &
ts_pid=$!
t0=$(date +%s)
runs 3
[ $(($(date +%s) - t0)) -le 10 ] || lw_fail "wwan-recover waited for a hung tailscale"
lw_expect_eq "$(reboot_runs)" "" "restarts of the router with a hung CLI"
lw_expect_eq "$(cat "$T/events")" "" "calls with a hung CLI"
kill "$ts_pid" 2>/dev/null || :
for p in $(pgrep -f 'sleep 3600' || :); do kill "$p" 2>/dev/null || :; done
wait "$ts_pid" 2>/dev/null || :
check_format
echo ok
