# R68b, R28, R77, D161: the restart of Tailscale on a request reads the router's own reading of the
# internet, the newest line of the signal log, which on a session with both families has `loss` for
# IPv4 and `loss6` for IPv6, and on an IPv6-only session has IPv6 in `loss`. A healthy IPv6 is
# internet: the restart happens; a line with no answer in any of its families does not restart.
# shellcheck source=tests/tailscale/ts.inc
. /fw/tests/tailscale/ts.inc
ts_setup
LOG=/tmp/lw-signal.log

ts_init() {
    mkdir -p /etc/init.d
    cp /fw/tests/tailscale/stubs/init-tailscale /etc/init.d/tailscale
}
ts_restarts() { if [ -f "$D/init-calls" ]; then grep -c '^restart$' "$D/init-calls" || :; else echo 0; fi; }
# ts_line FIELDS: the newest line of the signal log with the given tail after wg_age
ts_line() {
    printf '2026-11-23_10:00:00 zsnt=6 net=LTE pb=B3 s1=? rsrp=-90dBm rsrq=-10dB sinr=12dB rssi=-60dBm pci=1 %s\n' \
        "$1" >"$LOG"
}
ts_removed() {
    ts_world
    ts_init
    ts_added $((BASE + 100 * 86400))
    ts_once
    : >"$D/offline"
    echo url >"$D/up-mode"
}
# shellcheck disable=SC2016  # the hook script expands $LW_TEST when it runs
ts_hook '[ -e /tmp/lw-tailscale/restart-at ] && [ ! -e /tmp/lw-tailscale/restart-done ] &&
    [ ! -e "$LW_TEST/ts/restart-hold" ] && /bin/sleep 1; exit 0'

# link: the request of a removed router with the given line; prints "EXIT RESTARTS"
link() {
    ts_removed
    ts_line "$1"
    rc=0
    lw-tailscale link >/dev/null 2>&1 || rc=$?
    echo "$rc $(ts_restarts)"
}

# internet: restart, the request is answered with the link (exit 0)
for tail in \
    'loss=0% rtt=36.4 wg_age=?' \
    'loss=33% rtt=36.4 wg_age=?' \
    'loss=0% rtt=21.5 wg_age=?' \
    'loss=100% rtt=? wg_age=? loss6=0% rtt6=21.5' \
    'loss=0% rtt=36.4 wg_age=? loss6=100% rtt6=?' \
    'loss=? rtt=? wg_age=? loss6=40% rtt6=21.5' \
    'loss=0% rtt=36.4 wg_age=? loss6=0% rtt6=21.5'; do
    lw_expect_eq "$(link "$tail")" "0 1" "R68b, R77: restart for '$tail'"
done

# no answer in any family: no restart, the state as it stands (exit 2)
for tail in \
    'loss=100% rtt=? wg_age=?' \
    'loss=? rtt=? wg_age=?' \
    'loss=100% rtt=? wg_age=? loss6=100% rtt6=?' \
    'loss=? rtt=? wg_age=? loss6=? rtt6=?' \
    'loss=100% rtt=? wg_age=? loss6=?'; do
    lw_expect_eq "$(link "$tail")" "2 0" "R68b, R77: no restart for '$tail'"
done

# `loss6` is not `loss`: a line with only the IPv6 field, as a damaged one could be, is not read
# as the IPv4 reading, and the other way round
lw_expect_eq "$(link 'wg_age=? loss6=0% rtt6=21.5')" "0 1" "R77: loss6 alone counts as internet"
lw_expect_eq "$(link 'wg_age=? xloss=0%')" "2 0" "R68b: a longer key is not loss"
echo ok
