# shellcheck shell=sh
# Shared setup for tests/tailscale/*.sh (sourced; no .sh suffix, so run-all.sh does not run it).
# Every test runs /usr/sbin/lw-tailscale as installed in the rootfs sandbox against the CLI stand-in
# in tests/tailscale/stubs (see its header for the files that drive it). A `once` is one start of the
# service with one pass; a restart of the router is ts_reboot (RAM gone, flash stays).
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
PATH=/fw/tests/tailscale/stubs:/fw/tests/tailscale/clock:$PATH
export PATH

D=$T/ts
SENT=/etc/tailscale/lw-sent
KEY=/etc/tailscale/lw-authkey
FAKE_KEY=tskey-auth-FAKEKEY0000000000
SET_ARGS='--netfilter-mode=off --accept-dns=false --accept-routes=false'
BASE=1900000000

# ts_world: the router's settings and the world of the stand-in, from the first start of a flashed
# router with Tailscale on and no key. Does not touch what lw_setup built.
ts_world() {
    rm -rf "$D" /etc/tailscale /tmp/lw-tailscale
    mkdir -p "$D" /etc/tailscale
    touch /etc/config/lonewrt
    uci set lonewrt.tailscale=tailscale
    uci set lonewrt.tailscale.enabled=1
    uci set lonewrt.tailscale.advertise_lan=0
    uci set lonewrt.tailscale.lan_prefix=192.168.5.0/24
    touch /etc/config/system
    uci set system.sys=system
    uci set system.sys.hostname=lw-test-rtr
    uci commit lonewrt
    uci commit system
    echo $BASE >"$T/wall"
    : >"$T/ntp"
    export LW_TS_WALL=$T/wall LW_TS_NTP=$T/ntp
}

ts_setup() {
    lw_setup
    ts_world
}

# ts_key: the profile's key file as the first start leaves it
ts_key() {
    printf '%s\n' "$FAKE_KEY" >"$KEY"
    chmod 600 "$KEY"
}

# ts_reboot: what a restart of the router does to the service's world (RAM is gone, flash stays)
ts_reboot() { lw_reboot_sim "${1:-60}"; }

ts_backend() { echo "$1" >"$D/backend"; }
ts_down() { rm -f "$D/backend"; }
ts_wall() { echo "$1" >"$T/wall"; }

# ts_iso EPOCH: the time as Tailscale prints it
ts_iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

# ts_added [EXPIRY_EPOCH]: Tailscale reports an added router; no argument = key expiry off
ts_added() {
    ts_backend Running
    echo rtr.tail1234.ts.net. >"$D/dnsname"
    echo 'fd7a:115c:a1e0::1 100.64.0.5' >"$D/ips"
    echo owner@example.com >"$D/tailnet"
    rm -f "$D/authurl" "$D/keyexpiry"
    [ -z "${1:-}" ] || ts_iso "$1" >"$D/keyexpiry"
}

ts_once() { lw-tailscale once; }

# ts_st KEY: a value of the state file
ts_st() { sed -n "s/^$1=//p" /tmp/lw-tailscale/state; }

# ts_due: the due messages on one line
ts_due() { lw-tailscale due | tr '\n' ' ' | sed 's/ $//'; }

ts_calls() { cat "$D/calls" 2>/dev/null || :; }
ts_count() { if [ -f "$D/calls" ]; then grep -c "^$1 " "$D/calls" || :; else echo 0; fi; }

# ts_hook SCRIPT: what runs after every nap of the loop (the world changes between its passes)
ts_hook() {
    printf '#!/bin/sh\n%s\n' "$1" >"$T/on-sleep"
    chmod +x "$T/on-sleep"
}

# ts_syslog: the lw-tailscale lines of the syslog without their uptime, one per line
ts_syslog() { sed -n 's/^[0-9]* lw-tailscale: //p' "$T/syslog"; }
