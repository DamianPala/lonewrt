#!/usr/bin/env bash
# SPEC R59e, D121, R59c: the comparison block of the skill (step 7.1) names the keys that differ
# between a profile and the router's uci settings and never prints a value. It runs here exactly as
# the skill has it, in a scratch folder, against the made-up profile below and a stand-in for ssh.
# shellcheck source=tests/build/lib.bash
source "$(dirname "$0")/../build/lib.bash"
scratch skillcmp
mkdir -p "$SCRATCH/bin" "$SCRATCH/profiles"

# the block: the fenced code that starts with the line `profile=profiles/<name>.conf ...`
awk '/^```sh$/ { buf = ""; inb = 1; next } /^```$/ { if (inb && buf ~ /^profile=profiles/) printf "%s", buf; inb = 0; next } inb { buf = buf $0 "\n" }' \
    "$FW/skills/lonewrt/SKILL.md" >"$SCRATCH/block.sh"
[ -s "$SCRATCH/block.sh" ] || fail "R59e: the comparison block is not in the skill"
sed -i -e 's#profiles/<name>.conf#profiles/cmp.conf#' -e 's#root@<router>#root@router.invalid#' "$SCRATCH/block.sh"

# a router whose settings are given by files named after the uci option; no file means unset
cat >"$SCRATCH/bin/ssh" <<'STUB'
#!/bin/sh
for last; do :; done
opt=${last#uci -q get }
[ -f "$ROUTER_STATE/$opt" ] && cat "$ROUTER_STATE/$opt"
exit 0
STUB
chmod +x "$SCRATCH/bin/ssh"

# set_router OPTION VALUE...: the router's current value of a uci option
set_router() {
    mkdir -p "$SCRATCH/state"
    local opt=$1
    shift
    printf '%s\n' "$*" >"$SCRATCH/state/$opt"
}
run_block() { (cd "$SCRATCH" && PATH="$SCRATCH/bin:$PATH" ROUTER_STATE="$SCRATCH/state" bash block.sh 2>&1); }

cat >"$SCRATCH/profiles/cmp.conf" <<'PROFILE'
WG_ENABLED='1'
WG_PRIVATE_KEY='fake-wg-private-q7x9'
WG_ADDRESS='10.99.77.2/32 10.99.77.3/32'
WG_PEER_PUBLIC_KEY='fake-wg-peer-q7x9'
WG_ENDPOINT_HOST='vpn.fake-q7x9.example'
WG_ENDPOINT_PORT='51820'
WG_ALLOWED_IPS='10.99.77.0/24,10.99.78.0/24'
WG_KEEPALIVE='25'
WWAN_APN='fake.apn.q7x9'
WWAN_AUTH=''
WWAN_USERNAME='fakeuser-q7x9'
WWAN_PASSWORD='fakepass-q7x9'
LTE_BANDS='3,20'
WIFI_KEY='fake-wifi-key-q7x9'
PROFILE
mkdir -p "$SCRATCH/state"
set_router network.wg0.private_key fake-wg-private-q7x9
set_router network.wg0.addresses 10.99.77.2/32 10.99.77.3/32
set_router network.wg_server.public_key fake-wg-peer-q7x9
set_router network.wg_server.endpoint_host vpn.fake-q7x9.example
set_router network.wg_server.endpoint_port 51820
set_router network.wg_server.allowed_ips 10.99.77.0/24 10.99.78.0/24
set_router network.wg_server.persistent_keepalive 25
set_router network.wwan.apn fake.apn.q7x9
set_router network.wwan.username fakeuser-q7x9
set_router network.wwan.password fakepass-q7x9
set_router lonewrt.modem.bands 3,20

got=$(run_block)
[ "$got" = "keys that differ: none" ] || fail "R59e: a matching router gave: $got"

# changes: the endpoint, the bands (the list order is kept), the tunnel switched off on the router
set_router network.wg_server.endpoint_host other.fake-q7x9.example
set_router lonewrt.modem.bands 3,7
set_router network.wg0.disabled 1
got=$(run_block)
[ "$got" = "keys that differ: WG_ENABLED WG_ENDPOINT_HOST LTE_BANDS" ] || fail "R59e: the changed keys came out as: $got"

# R59c: no value of the profile or of the router in the output
for v in fake-wg-private-q7x9 fake-wg-peer-q7x9 vpn.fake-q7x9 other.fake-q7x9 fake.apn.q7x9 fakeuser-q7x9 fakepass-q7x9 10.99.77; do
    ! grep -qF -- "$v" <<<"$got" || fail "R59c: the output holds a value ($v)"
done
echo "tunnel-limit comparison names the keys that differ and prints no value"
