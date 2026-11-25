#!/usr/bin/env bash
# What the first slice of IPv4 over an IPv6-only session left unverified (SPEC R76 to R76e, R77, R14f,
# R23; 95-clat.sh is the scenario of the slice itself). One router guest with the real stock 464xlat, the
# kmod-nat46 module, a WireGuard tunnel and Tailscale (an image of a profile with TS_ENABLED and
# WG_ENABLED), the operator stand-in tests/vm/nat64-peer.py as the other end of its wwan NIC, and a
# second guest that is a WireGuard peer reachable only by IPv4, behind the NAT64:
#
#   1  WireGuard over the translation: handshake, and the largest ping that passes inside the tunnel
#      (the image's MTU of 1400) with the link at 1500 and at 1430
#   2  Tailscale beside the translation: the rules of `ip rule` and `ip -6 rule` of both live side by
#      side, IPv4 works, and the end of the translation takes away only its own rules
#   3  the NAT64 gone while the helper lives: a moved prefix is followed, the same prefix or no answer
#      of the DNS64 gives one line and no restart
#   4  `ifdown wwan` with no `ifup` after it leaves nothing that blocks the next session
#   5  the operator renumbers the /64 in the middle of the session
#
#   tests/vm/96-clat-verify.sh
#
# Nothing leaves the host: the WireGuard peer is a guest on user-mode networking with one UDP port
# forwarded from the host, and the NAT64 hands the UDP datagrams to that port. Keys are made by the test
# and live in the two guests' RAM.
# shellcheck disable=SC2016,SC2119 # guest scripts expand in the guest; helper args are optional
# shellcheck disable=SC2153 # PFX comes from clat-lib.sh
# shellcheck disable=SC2329 # scenarios pass callbacks to must/check and the EXIT trap
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=clat-lib.sh
. "$VMDIR/clat-lib.sh"
SCENARIO=clat-verify

LAN=192.168.213.1
WGRUN=$VMWORK/run/$SCENARIO-wg
ENDPOINT=198.51.100.7
WG_R=10.99.0.1
WG_P=10.99.0.2
PFX2=3fff:64:7777::/96
NEW64=2001:db8:64:200::/64
IMG_RT=
IMG_WG=
WGPORT=

cv_cleanup() {
    if [ -d "$WGRUN" ]; then vm_py stop --run "$WGRUN" || true; fi
    vm_cleanup
    peer_stop
}
trap cv_cleanup EXIT

wg_sh() { RUN=$WGRUN vm_sh "$@"; }

# ---- images ----------------------------------------------------------------------------------------

# cv_profile: generic.conf with a tunnel and Tailscale on, the keys made up (the test sets real ones in
# the guests), in $VMWORK/profiles/clat-vm.conf; the same profile renders the same image, so it is cached
cv_profile() {
    local f kv
    mkdir -p "$VMWORK/profiles"
    cp "$FW/profiles/generic.conf" "$VMWORK/profiles/generic.conf"
    f=$VMWORK/profiles/clat-vm.conf
    cp "$FW/profiles/generic.conf" "$f"
    chmod 600 "$f"
    for kv in HOSTNAME=lwvm-clat "LAN_IP=$LAN" TS_ENABLED=1 TS_ADVERTISE_LAN=1 WIFI_KEY=lwvm-wifi-key \
        "ROOT_PASSWORD_HASH=$(openssl passwd -6 -salt lwvmtest lwvm-test-password)" \
        WG_ENABLED=1 'WG_PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' "WG_ADDRESS=$WG_R/24" \
        'WG_PEER_PUBLIC_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAE=' "WG_ENDPOINT_HOST=$ENDPOINT" \
        WG_ENDPOINT_PORT=51820 WG_ALLOWED_IPS=10.99.0.0/24; do
        K=${kv%%=*} V=${kv#*=} awk '
            index($0, ENVIRON["K"] "=") == 1 { print ENVIRON["K"] "=\047" ENVIRON["V"] "\047"; next }
            { print }' "$f" >"$f.new"
        cat "$f.new" >"$f"
        rm -f "$f.new"
    done
}

build_images() {
    mkdir -p "$VMWORK/logs"
    cv_profile
    rm -rf "$VMWORK/render/clat-vm" "$VMWORK/render/clat-vm-passwords.txt"
    LW_PROFILES=$VMWORK/profiles "$FW/build.sh" --render-only clat-vm "$VMWORK/render/clat-vm" \
        >"$VMWORK/logs/clat-verify-render.log" 2>&1 || return 1
    IMG_RT=$(LWVM_NO_CURRENT=1 LWVM_LAN_IP=$LAN "$VMDIR/build-image.sh" "$VMWORK/render/clat-vm" \
        2>"$VMWORK/logs/clat-verify-image.log" | tail -n1) || true
    IMG_WG=$("$VMDIR/build-lan-guest.sh" 2>"$VMWORK/logs/clat-verify-image-wg.log" | tail -n1) || true
    [ -f "$IMG_RT/disk.img" ] && [ -f "$IMG_WG/disk.img" ]
}

free_udp_port() { python3 -I -c 'import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

# hold NAME: with LWVM_CLAT_HOLD=NAME the scenario stops here until the file $RUN/done exists, to look at the
# guests by hand (tests/vm/vm.py sh --run DIR 'command')
hold() {
    [ "${LWVM_CLAT_HOLD:-}" = "$1" ] || return 0
    echo "LWVM-CLAT-HOLD $1: router in $RUN, WireGuard peer in $WGRUN, create $RUN/done to go on"
    until [ -e "$RUN/done" ]; do sleep 2; done
}

# ---- the pieces ------------------------------------------------------------------------------------

# NOTRANS: nothing of a translation is left: no interface, helper, device, marker or rule of it
NOTRANS='! ubus call network.interface.wwan_6_4 status >/dev/null 2>&1 && [ "$(ps w | grep -c "[4]64xlatcfg")" = 0 ] &&
    [ ! -e /sys/class/net/464-wwan_6_4 ] && ! ls /tmp/464-*-anycast >/dev/null 2>&1 && [ ! -e /var/run/lw-clat/active ] &&
    [ "$(ip -6 rule | grep -c "from all lookup local")" = 1 ] && [ "$(ip -6 rule | grep -c prelocal)" = 0 ]'

# helper_pid / wwan_uptime / sixfour_uptime: read in the router
helper_pid() { vm_sh 'cat /var/run/464-wwan_6_4.pid' | tr -d '\r'; }
wwan_uptime() { vm_sh 'ubus call network.interface.wwan status | jsonfilter -e "@.uptime"' | tr -d '\r'; }

# count_on: the DNS64 questions of the check, counted per output device (R76a: the query
# has to leave on the child's device), as in 95-clat.sh
DNSQ='ip6 daddr 2001:db8:64::53 udp dport 53 meta length 79'
count_on() {
    vm_sh "nft delete table inet c2count 2>/dev/null; nft add table inet c2count
nft 'add chain inet c2count out { type filter hook output priority -300; policy accept; }'
nft add rule inet c2count out $DNSQ oifname wwan0 counter
nft add rule inet c2count out $DNSQ oifname br-lan counter" 30
}

# the WireGuard peer: a guest on user-mode networking, UDP port 51820 reached through the host's WGPORT
wg_peer_start() {
    rm -rf "$WGRUN"
    mkdir -p "$WGRUN"
    cp --reflink=auto "$IMG_WG/disk.img" "$WGRUN/disk.img"
    vm_py start --run "$WGRUN" --guest --udp-fwd "$WGPORT:51820" >>"$WGRUN/harness.log"
    RUN=$WGRUN vm_wait_ready 120
    # slirp passes a guest's reply to a forwarded port only when the guest is not restricted; the guest
    # is given no way out beyond the host's one port: no default route (the DHCP lease brings one)
    wg_sh 'ip route del default 2>/dev/null; ! ip route | grep -q ^default' >/dev/null
}

# wg_setup: the keys, made here; the peer listens, the router's wg0 (the image's: MTU 1400, zone vpn)
# gets the peer's key and the endpoint that only the NAT64 reaches
wg_setup() {
    local rpub ppub
    rpub=$(vm_sh 'umask 077; wg genkey >/tmp/wg.key; wg pubkey </tmp/wg.key' | tr -d '\r')
    ppub=$(wg_sh 'umask 077; wg genkey >/tmp/wg.key; wg pubkey </tmp/wg.key' | tr -d '\r')
    [ ${#rpub} = 44 ] && [ ${#ppub} = 44 ] || return 1
    wg_sh "ip link add wg0 type wireguard && wg set wg0 private-key /tmp/wg.key listen-port 51820 peer $rpub allowed-ips $WG_R/32 &&
ip addr add $WG_P/24 dev wg0 && ip link set wg0 up" >/dev/null || return 1
    vm_sh "uci set network.wg0.private_key=\"\$(cat /tmp/wg.key)\"
uci set network.wg_server.public_key='$ppub'
uci set network.wg_server.endpoint_host='$ENDPOINT'
uci commit network
ifdown wg0; ifup wg0
i=0; until wg show wg0 endpoints 2>/dev/null | grep -q '$ENDPOINT:51820' && ip link show wg0 | grep -q '<.*UP'; do
    i=\$((i + 1)); [ \$i -lt 40 ] || exit 1; sleep 1; done" 90 >/dev/null
}

# WG_SWEEP: the largest ping payload that passes through the tunnel (two tries per size: the first
# packet after a change may be lost on a slow guest), 1372 being the full size of the image's MTU of 1400
WG_SWEEP='ok() { ping -s "$1" -c 1 -W 2 10.99.0.2 >/dev/null 2>&1 || ping -s "$1" -c 1 -W 2 10.99.0.2 >/dev/null 2>&1; }
ok 1372 && { echo 1372; exit 0; }
lo=16 hi=1372
ok $lo || { echo 0; exit 0; }
while [ $((hi - lo)) -gt 1 ]; do
    m=$(((lo + hi) / 2))
    if ok $m; then lo=$m; else hi=$m; fi
done
echo $lo'
wg_sweep() { vm_sh "$WG_SWEEP" 600 | tr -d '\r'; }

# DF: busybox ping has no option for the DF bit, and a ping larger than wg0's MTU is split into fragments
# that fit it, which would make a too large tunnel look as if it worked. So fragmentation at wg0 is refused
# instead: an nft table before the defragmentation of conntrack (priority -500) drops every IP fragment
# that leaves on wg0 or comes in on it, in both directions of the tunnel (what a packet with DF set
# gets: no way through when it does not fit)
DF_ON='nft delete table inet c2df 2>/dev/null; nft add table inet c2df
nft "add chain inet c2df out { type filter hook output priority -500; policy accept; }"
nft "add chain inet c2df in { type filter hook prerouting priority -500; policy accept; }"
nft add rule inet c2df out oifname wg0 ip frag-off "&" 0x3fff != 0 counter drop
nft add rule inet c2df in iifname wg0 ip frag-off "&" 0x3fff != 0 counter drop'
df_on() { vm_sh "$DF_ON" 30; }
df_off() { vm_sh 'nft delete table inet c2df' 30; }

# link_mtu N: the link between the router and the operator has this MTU, at both ends
link_mtu() {
    pset mtu "$1"
    vm_sh "ip link set dev wwan0 mtu $1; ip route flush cache; ip -6 route flush cache" 30 >/dev/null
}

# ---- the scenario ----------------------------------------------------------------------------------

build_images || { echo "  FAIL  images build (see $VMWORK/logs/clat-verify-*.log)"; exit 1; }
echo "  ok    images build (router with WireGuard and Tailscale, WireGuard peer)"
# shellcheck disable=SC2034 # read by vm_init in lib.sh
IMAGE=$IMG_RT
WGPORT=$(free_udp_port)
vm_init
peer_start || { echo "  FAIL  the operator stand-in does not listen"; exit 1; }
echo "  ok    the operator stand-in listens"
vm_start --wwan-peer "$RUN/wwan.sock"
must "router boots to the end of its init scripts" vm_wait_ready
note "packages: $(grep -E '^(464xlat|kmod-nat46|wireguard-tools|tailscale) ' "$IMG_RT/manifest" | tr '\n' ' ')"
must "the bench's DNAT of the two ping targets is out of the way" vm_sh 'nft delete table ip lwvm'
must "the stand-in protocol replaces qmi on wwan, dual stack first (no translation)" vm_sh \
    'uci set network.wwan.proto=lwvm; uci -q delete network.lwvm_default; uci set network.wwan.mode=dual; uci commit network
/etc/init.d/network reload' 60
must "wwan is up with both calls" wwan_up
must "Tailscale's rules are in place before any translation (tailscaled is not added to an account)" vm_wait_for \
    'ip rule | grep -q "lookup 52" && ip -6 rule | grep -q "lookup 52" && [ "$(lw-tailscale status | sed -n "s/^state=//p")" = not_added ]' 120
must "the rules of both families are written down: before the translation" vm_sh 'ip rule >/tmp/r4-before; ip -6 rule >/tmp/r6-before'
gnote 'cat /tmp/r4-before; echo ---; cat /tmp/r6-before'
check "no translation in a dual-stack session" no_translation

echo "# IPv6-only session with the translation"
must "counters for the DNS queries, per device" count_on
must "IPv6-only session" wwan_mode v6
must "wwan is up with an IPv6 call" wwan_up
must "wwan_6 runs odhcp6c" child_up
must "the translation comes up on 464-wwan_6_4" translated
gcheck "the router reaches 8.8.8.8 through the translation (the first packets may be lost, see PING_OK)" "$PING_OK; ping -c 2 -W 3 8.8.8.8"
gnote 'ip -6 rule; ip -4 rule; ip link show 464-wwan_6_4 | head -n 1; cat /tmp/464-wwan_6_4-anycast; ip -4 route show default; ip link show wwan0 | head -n 1'

# ---- 1: WireGuard over the translation -------------------------------------------------------------------
echo "# 1: WireGuard through the translation to a peer reachable only by IPv4"
must "the WireGuard peer boots (a guest behind the NAT64, user-mode networking)" wg_peer_start
pset udp-forward "51820 127.0.0.1 $WGPORT"
must "keys made, the peer listens, the router's wg0 has its key, the peer's key and the endpoint $ENDPOINT:51820" wg_setup
gcheck "the router's wg0 has the image's MTU of 1400" 'ip link show wg0 | grep -q "mtu 1400"'
hold wg
gcheck "the handshake works through the translation (the first packets may be lost, so a few tries)" \
    'i=0; until ping -c 1 -W 2 10.99.0.2 >/dev/null 2>&1; do i=$((i + 1)); [ $i -lt 10 ] || exit 1; done
     wg show wg0 latest-handshakes | awk "{ exit !(\$2 > 0) }"' 120
check "the NAT64 saw the UDP flow to the endpoint" test "$(plog "^udp4 $ENDPOINT 51820 ")" -ge 1
gcheck "the tunnel carries a ping both ways (the peer's wg0 counted the router's packets)" \
    'ping -c 3 -W 3 10.99.0.2 >/dev/null && wg show wg0 transfer | awk "{ exit !(\$2 > 0 && \$3 > 0) }"' 60
gnote 'ip -4 route get 198.51.100.7; ip link show 464-wwan_6_4 | head -n 1; ip link show wwan0 | head -n 1'

must "fragmentation at wg0 is refused from now on (DF for every packet of the tunnel)" df_on
check "the refusal works: a ping of 1400 bytes, which wg0 of 1400 would split, does not pass" \
    vm_sh '! ping -s 1400 -c 2 -W 2 10.99.0.2 >/dev/null 2>&1' 60
W1500=$(wg_sweep)
note "RESULT link MTU 1500, DF: largest ping payload through the tunnel $W1500 (inner packet $((W1500 + 28)), outer IPv4 $((W1500 + 88)), outer IPv6 after the translation $((W1500 + 108)))"
check "the full size of the tunnel (1400) passes with the link at 1500" test "$W1500" = 1372
check "the NAT64 dropped nothing for size at 1500" test "$(plog '^toobig ')" = 0

link_mtu 1430
sleep 2
W1430=$(wg_sweep)
note "RESULT link MTU 1430, DF, no Packet Too Big from the operator: largest ping payload $W1430 (inner packet $((W1430 + 28)), outer IPv6 after the translation $((W1430 + 108)))"
gnote 'ip -4 route get 198.51.100.7; ip link show 464-wwan_6_4 | head -n 1; ip link show wwan0 | head -n 1; ip -s link show wwan0 | head -n 6'
note "toobig lines of the peer so far: up $(plog '^toobig up ') down $(plog '^toobig down ')"
echo "$W1430" >"$RUN/wg-1430"
pset ptb on
sleep 2
W1430P=$(wg_sweep)
note "RESULT link MTU 1430, DF, with Packet Too Big from the operator: largest ping payload $W1430P"
check "the full size of the image's tunnel (1372) does not pass on the link of 1430 with DF: the finding" \
    test "$W1430" -lt 1372 -a "$W1430P" -lt 1372
gnote 'ip -4 route get 198.51.100.7; ip link show 464-wwan_6_4 | head -n 1'
pset ptb off
# the image's MTU of the tunnel is 1400; what the link allows is the link MTU less the 80 bytes that the
# outer IPv4 header (20), UDP (8), WireGuard (32) and the IPv6 header after the translation (20) cost.
# with DF (above) the largest ping that passes at wg0 1350 on both ends is the one that fills it: 1322 + 28 = 1350
vm_sh 'ip link set dev wg0 mtu 1350' >/dev/null
wg_sh 'ip link set dev wg0 mtu 1350' >/dev/null
sleep 2
W1350=$(wg_sweep)
note "RESULT link MTU 1430, DF, wg0 at 1350 (link less 80), both ends: largest ping payload $W1350 (inner packet $((W1350 + 28)), outer IPv6 after the translation $((W1350 + 108)))"
check "wg0 at the link's MTU less 80, at both ends, passes its full size (1350 inner) on the link of 1430 with DF" test "$W1350" = 1322
vm_sh 'ip link set dev wg0 mtu 1400' >/dev/null
wg_sh 'ip link set dev wg0 mtu 1420' >/dev/null
link_mtu 1500
sleep 2
check "back at the link of 1500 and wg0 of 1400 the full size passes again" test "$(wg_sweep)" = 1372
must "fragmentation at wg0 is allowed again" df_off
# the tunnel is not needed any more: its packets (a rekey, a keepalive) are traffic on wwan0 that the ladder's
# runs of the sections below would take for the link being alive
must "wg0 is down: no traffic of its own on the link from here on" vm_sh 'ifdown wg0; ! ip link show wg0 >/dev/null 2>&1 || ip link show wg0 | grep -qv "<.*UP"' 60

# ---- 2: Tailscale beside the translation ---------------------------------------------------------------------
echo "# 2: Tailscale's rules beside the translation's"
gcheck "R76e: the IPv4 rules are those from before the translation, Tailscale's 5210 to 5270 among them" \
    '[ "$(ip rule)" = "$(cat /tmp/r4-before)" ] && [ "$(ip rule | grep -c "^52[1-7]0:")" = 4 ]'
gcheck "R76e: Tailscale's IPv6 rules are those from before, and the translation's two are there beside them" \
    '[ "$(ip -6 rule | grep "^52")" = "$(grep "^52" /tmp/r6-before)" ] && [ "$(ip -6 rule | grep -c "^52[1-7]0:")" = 4 ] &&
     [ "$(ip -6 rule | grep -c "^0:.*to .* lookup prelocal")" = 1 ] && [ "$(ip -6 rule | grep -c "^1:.*from all lookup local")" = 1 ]'
gcheck "R76: IPv4 through the translation works with both sets of rules in place (see PING_OK)" "$PING_OK; ping -c 2 -W 3 8.8.8.8"
gcheck "R76e: Tailscale is not touched: the same state, the same table 52" \
    '[ "$(lw-tailscale status | sed -n "s/^state=//p")" = not_added ] && ip -6 route show table 52 >/dev/null 2>&1'
note "the translation ends by a switch to dual stack: only its own rules go"
must "a dual-stack session" wwan_mode dual
must "wwan is up" wwan_up
check "no translation any more" vm_wait_for "$NOTRANS" 90
gcheck "R76e: both rule sets are what they were before the translation, byte for byte" \
    '[ "$(ip rule)" = "$(cat /tmp/r4-before)" ] && [ "$(ip -6 rule)" = "$(cat /tmp/r6-before)" ]'
gnote 'ip -6 rule; ip rule'
pset prefix "$PFX"
must "an IPv6-only session again" wwan_mode v6
must "wwan is up" wwan_up
must "wwan_6 runs odhcp6c" child_up
must "the translation is up" translated 90
check "one helper, one device, one set of rules" one_translation
gcheck "the first packets go through (see PING_OK)" "$PING_OK"

# ---- 3: the NAT64 gone while the helper lives (R76a, R76c) ---------------------------------------------------
echo "# 3: the operator's NAT64 gone while the helper lives"
RECOVER='/usr/sbin/wwan-recover'
# the image's cron runs the ladder every 5 minutes: with it running, a count of "exactly three runs" is
# not one, and a hold on the ladder's own lock would let a run exit 0 without having run. It is stopped
# for the rest of the scenario, so every run of wwan-recover here is the test's own
must "cron is stopped: the ladder runs only when the test runs it" \
    vm_sh '/etc/init.d/cron stop; i=0; while pidof crond >/dev/null; do i=$((i + 1)); [ $i -lt 10 ] || exit 1; sleep 1; done; ! pidof crond' 60
helper_age() { vm_sh 'ubus call network.interface.wwan_6_4 status | jsonfilter -e "@.uptime"' | tr -d '\r'; }
# packets of the DNS64 question that left on wwan0 since count_on, and on the LAN bridge
dnsq_wwan0() { vm_sh 'nft list chain inet c2count out | awk "/oifname \"wwan0\"/ { for (i = 1; i < NF; i++) if (\$i == \"packets\") print \$(i + 1) }"' 30 | tr -d '\r'; }
dnsq_lan() { vm_sh 'nft list chain inet c2count out | awk "/oifname \"br-lan\"/ { for (i = 1; i < NF; i++) if (\$i == \"packets\") print \$(i + 1) }"' 30 | tr -d '\r'; }

must "counters for the DNS queries, from zero" count_on
P0=$(helper_pid)
note "a run of the ladder with every probe passing: the DNS64 is not asked"
must "a ladder run, probes pass" vm_sh "$RECOVER" 300
check "R76c: nothing asked, nothing logged when the probes pass" test "$(dnsq_wwan0)" = 0
HA=$(helper_age)

echo "# 3a: the NAT64 is dead, the DNS64 still gives the same prefix"
pset nat64 off
for i in 1 2 3; do
    must "ladder run $i with the NAT64 dead" vm_sh "$RECOVER" 300
    note "after run $i: $(dnsq_wwan0) DNS64 questions so far"
done
gnote 'logread | grep -E "wwan-recover|lw-clat" | tail -n 30'
note "questions of the DNS64 that left on wwan0: $(dnsq_wwan0), on br-lan: $(dnsq_lan)"
gnote 'nft list chain inet c2count out; logread | grep -E "lw-clat|wwan-recover" | tail -n 12; ls -la /var/run/lw-clat'
hold 3a
check "R76a, R76c: one DNS64 question per ladder run, on the checked path (wwan0), none on the LAN" \
    test "$(dnsq_wwan0)" = 3 -a "$(dnsq_lan)" = 0
check "R76a: the same helper, no restart: pid $P0 still" test "$(helper_pid)" = "$P0"
check "R76a: the interface of the translation was not rebuilt (uptime grew from $HA)" \
    test "$(helper_age)" -ge "$HA"
check "R76a: exactly one log line for the dead NAT64, not one per run" \
    test "$(vm_sh 'logread | grep -c "DNS64 still gives its prefix"' | tr -d '\r')" = 1
check "R76c: and one set of rules, one device, one helper" one_translation
note "the lines of the check: $(vm_sh 'logread | grep lw-clat | tail -n 4' | tr '\n' '|')"
pset nat64 on
must "ladder run, the NAT64 is back, every probe passes" vm_sh "$RECOVER" 300
check "the same helper still works: IPv4 answers" vm_sh "$PING_OK" 60
check "no DNS64 question since the NAT64 came back" test "$(dnsq_wwan0)" = 3

echo "# 3b: the operator moved the NAT64 to another prefix"
pset prefix "$PFX2"
check "the old prefix is dead now: no answer through the translation as it is" \
    vm_sh '! ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1' 30
must "one ladder run" vm_sh "$RECOVER" 300
gnote 'logread | grep -E "lw-clat|wwan-recover" | tail -n 12; ps w | grep "[4]64xlat"'
hold 3b
check "R76a, R76c: the translation was made again within that one run (new helper, new prefix)" \
    vm_wait_for "ps w | grep '[4]64xlatcfg' | grep -q '$PFX2' && ! ps w | grep '[4]64xlatcfg' | grep -q '3fff:64:6464'" 60
check "the translation is up" translated 60
gcheck "the first packets go through the new prefix (see PING_OK)" "$PING_OK; ping -c 2 -W 3 8.8.8.8"
check "R76c: one helper, one device, one set of rules after it" one_translation
check "R76a: a line says what happened" \
    test "$(vm_sh 'logread | grep -c "the DNS64 gives .* now and translated IPv4 does not answer"' | tr -d '\r')" = 1

# ---- 5: the operator renumbers the /64 in the middle of the session ------------------------------------------
echo "# 5: the /64 changes in the middle of the session"
OLD64=2001:db8:64:100:
NEW64P=2001:db8:64:200:
OLDADDR=$(vm_sh 'cat /tmp/464-wwan_6_4-anycast' | tr -d '\r')
note "the translation's address before the renumbering: $OLDADDR"
gnote 'ip -6 route show table all | grep -F "$(cat /tmp/464-wwan_6_4-anycast)"; ip -6 rule | grep -F "$(cat /tmp/464-wwan_6_4-anycast)"'
must "the operator advertises another /64 and withdraws the old one" pset ra-prefix "$NEW64"
check "the child follows to the new /64" child_up "$NEW64P"
if vm_wait_for "grep -q '^$NEW64P' /tmp/464-wwan_6_4-anycast" 40; then
    note "RESULT renumbering: the translation followed by the hotplug event alone"
    HOW=hotplug
else
    note "RESULT renumbering: the hotplug event did not make the translation again within 40 s, one ladder run does"
    vm_sh "$RECOVER" 300 >/dev/null
    HOW=ladder
fi
check "R76c: the translation's address is in the new /64 ($HOW)" \
    vm_wait_for "grep -q '^$NEW64P' /tmp/464-wwan_6_4-anycast" 60
check "the translation is up" translated 60
check "R76c: no rule for the old address" \
    vm_sh "! ip -6 rule | grep -qF '$OLDADDR'" 30
check "R76c: no route for the old address, in any table (the /128 netifd had for it)" \
    vm_sh "! ip -6 route show table all | grep -qF '$OLDADDR'" 30
check "R76c: one set of rules, for the new address" \
    vm_sh "[ \"\$(ip -6 rule | grep -c prelocal)\" = 1 ] && ip -6 rule | grep prelocal | grep -q '$NEW64P' &&
     ! ip -6 rule | grep prelocal | grep -q '$OLD64'" 30
check "one helper, one device" one_translation
gcheck "IPv4 works from the new address (see PING_OK)" "$PING_OK; ping -c 2 -W 3 8.8.8.8"
gcheck "the source of the translation is the new address: the peer saw echo from it" \
    'ping -c 1 -W 3 1.1.1.1 >/dev/null; true'
check "the NAT64 saw IPv4 from the new /64" test "$(plog "^echo4 1.1.1.1 $NEW64P")" -ge 1
check "the log says the /64 moved, once" \
    test "$(vm_sh 'logread | grep -c "moved to another /64"' | tr -d '\r')" = 1
note "renumbering followed by: $HOW"

# ---- 4: ifdown wwan with no ifup after it --------------------------------------------------------------------
echo "# 4: ifdown wwan, no ifup after it"
must "ifdown of wwan" vm_sh 'ifdown wwan'
check "no helper, interface, nat46 device, marker or rule of the translation" vm_wait_for "$NOTRANS" 60
gcheck "no pid file, no nat46 device in the module's control file" \
    '[ ! -e /var/run/464-wwan_6_4.pid ] && ! grep -q "^add 464-wwan_6_4" /proc/net/nat46/control'
gcheck "no rule of the translation in ip -6 rule, Tailscale's untouched" \
    '[ "$(ip -6 rule | grep -c "prelocal\|^1:")" = 0 ] && [ "$(ip -6 rule | grep -c "^52[1-7]0:")" = 4 ]'
gcheck "nothing in /var/run/lw-clat but the modem session's marker and the (free) lock file" \
    'for f in /var/run/lw-clat/*; do [ -e "$f" ] || continue; case $f in */v6only | */lock) ;; *) echo "left: $f"; exit 1 ;; esac; done'
gcheck "the lock is free, so the next run of the check is not kept out" 'flock -n /var/run/lw-clat/lock true'
gnote 'ls -la /var/run/lw-clat 2>&1; ip -6 rule; ps w | grep "[4]64xlat"'
note "the next session: ifup wwan, with the old prefix gone on the operator's side"
pset prefix "$PFX"
pset ra-prefix 2001:db8:64:300::/64
must "ifup of wwan" vm_sh 'ifup wwan'
must "wwan_6 is up, on a third /64" child_up 2001:db8:64:300:
check "the translation of the next session is up" translated 90
gcheck "IPv4 works (see PING_OK)" "$PING_OK; ping -c 2 -W 3 8.8.8.8"
check "one helper, one device, one set of rules" one_translation

finish
