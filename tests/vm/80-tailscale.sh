#!/usr/bin/env bash
# Tailscale of a tailscale image with the real x86 package (SPEC "Tailscale": R63c, R63d, R63e, R63h,
# R64, R64a, R65a, R65e, R66a, R66b, R72c, D149, D155, and the facts of the Tailscale section that the
# spec marks Unverified: what the real CLI prints and takes). Two guests: the router (a profile with
# TS_ENABLED='1' and TS_ADVERTISE_LAN='1', LAN 192.168.213.1, no Telegram) and a small LAN guest that
# gets its address from the router's DHCP, answers ping and logs the source of web requests (the
# router's LAN NIC is taken out of br-lan so the harness's own DHCP server stays out of the way).
# A third guest, with WG_ENABLED='1' and a made-up key and peer, runs first.
#
#   tests/vm/80-tailscale.sh                  no internet in the guests; what needs Tailscale's servers
#                                             reports SKIP
#   LWVM_INTERNET=1 ...                       the router's wwan NIC is NAT to the real internet: link,
#                                             refused key, no internet with a key, the real CLI. Nobody
#                                             signs in, so no node appears in any account.
#   LWVM_INTERNET=1 LWVM_TS_LIVE=1 ...        then writes the sign-in link to $RUN/ts-link.txt (0600),
#                                             prints `LWVM-TS-LINK-READY <path>` and waits for a person
#                                             to sign in: see tests/vm/README.md "Tailscale"
# Run it directly for LWVM_TS_LIVE (tests/vm/run-all.sh keeps stdout in a log). The sign-in link
# reaches only the 0600 file, never a log or stdout.
# shellcheck disable=SC2016,SC2119 # guest scripts expand in the guest; helper args are optional
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCENARIO=tailscale

INTERNET=${LWVM_INTERNET:-0}
LIVE=${LWVM_TS_LIVE:-0}
WAIT_S=${LWVM_TS_WAIT_S:-900}
HOLD_S=${LWVM_TS_HOLD_S:-1800}
PEER=${LWVM_TS_PEER:-}
LAN=192.168.213.1
PREFIX=192.168.213.0/24
# what lw-tailscale hands to `up` and `set` (R64), for the commands this scenario runs itself
TS_FLAGS="--netfilter-mode=off --accept-dns=false --accept-routes=false --advertise-routes=$PREFIX --hostname=lwvm-ts"
# format of a real key, key made up (R66)
FAKE_KEY=tskey-auth-kLwvmFakeCNTRL-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
LGRUN=$VMWORK/run/$SCENARIO-lan
SKIPS=0
IMG_TS=
IMG_WG=
IMG_LG=
LIVE_REPORT=
LG_N0=0

if [ "$LIVE" = 1 ] && [ "$INTERNET" != 1 ]; then
    echo "LWVM_TS_LIVE=1 needs LWVM_INTERNET=1" >&2
    exit 2
fi
if [ "$LIVE" = 1 ] && ! [[ $PEER =~ ^100\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "LWVM_TS_PEER (the owner's 100.x address) is not set: the ping steps will report SKIP" >&2
    PEER=
fi

skip() {
    SKIPS=$((SKIPS + 1))
    echo "  SKIP  $*"
}

# gshow DESC SCRIPT [TIMEOUT]: gcheck whose output stays in the log as notes, with every address and
# key in it replaced; the sign-in link must never reach the log
gshow() {
    local desc=$1 out rc=0
    out=$(vm_sh "$2" "${3:-60}" 2>&1) || rc=$?
    out=$(printf '%s\n' "$out" | sed -E 's#https?://[^[:space:]]+#<url>#g; s#tskey-[A-Za-z0-9-]+#<key>#g')
    CHECKS=$((CHECKS + 1))
    if [ "$rc" = 0 ]; then
        echo "  ok    $desc"
    else
        FAILS=$((FAILS + 1))
        echo "  FAIL  $desc"
    fi
    [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/          /'
}

lg_sh() { RUN=$LGRUN vm_sh "$@"; }
lg_check() { check "$1" lg_sh "$2" "${3:-60}"; }

ts_cleanup() {
    if [ -d "$LGRUN" ]; then vm_py stop --run "$LGRUN" || true; fi
    vm_cleanup
}
trap ts_cleanup EXIT

wan_link() { vm_py link "$1" --run "$RUN" >>"$RUN/harness.log"; }

# ---- images ---------------------------------------------------------------------------------------

# ts_profile NAME KEY=VALUE...: generic.conf with these values, in $VMWORK/profiles/NAME.conf. The
# root hash and the WiFi key are fixed, so the same profile renders the same image and it is cached.
ts_profile() {
    local name=$1 f kv
    shift
    mkdir -p "$VMWORK/profiles"
    cp "$FW/profiles/generic.conf" "$VMWORK/profiles/generic.conf"
    f=$VMWORK/profiles/$name.conf
    cp "$FW/profiles/generic.conf" "$f"
    chmod 600 "$f"
    for kv in HOSTNAME=lwvm-ts "LAN_IP=$LAN" TS_ENABLED=1 TS_ADVERTISE_LAN=1 WIFI_KEY=lwvm-wifi-key \
        "ROOT_PASSWORD_HASH=$(openssl passwd -6 -salt lwvmtest lwvm-test-password)" "$@"; do
        K=${kv%%=*} V=${kv#*=} awk '
            index($0, ENVIRON["K"] "=") == 1 { print ENVIRON["K"] "=\047" ENVIRON["V"] "\047"; next }
            { print }' "$f" >"$f.new"
        cat "$f.new" >"$f"
        rm -f "$f.new"
    done
}

# ts_image NAME: renders the profile and builds the image; prints the image directory
ts_image() {
    local name=$1
    rm -rf "$VMWORK/render/$name" "$VMWORK/render/$name-passwords.txt"
    LW_PROFILES=$VMWORK/profiles "$FW/build.sh" --render-only "$name" "$VMWORK/render/$name" \
        >"$VMWORK/logs/ts-render-$name.log" 2>&1 || return 1
    LWVM_NO_CURRENT=1 LWVM_LAN_IP=$LAN "$VMDIR/build-image.sh" "$VMWORK/render/$name" \
        2>"$VMWORK/logs/ts-image-$name.log" | tail -n1
}

build_images() {
    mkdir -p "$VMWORK/logs"
    ts_profile ts-vm
    ts_profile ts-wg WG_ENABLED=1 'WG_PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' \
        WG_ADDRESS=10.77.0.2/32 'WG_PEER_PUBLIC_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAE=' \
        WG_ENDPOINT_HOST=192.0.2.1 WG_ENDPOINT_PORT=51820 WG_ALLOWED_IPS=10.77.0.0/24 WG_KEEPALIVE=25
    IMG_TS=$(ts_image ts-vm) || true
    IMG_WG=$(ts_image ts-wg) || true
    IMG_LG=$("$VMDIR/build-lan-guest.sh" 2>"$VMWORK/logs/ts-image-lan-guest.log" | tail -n1) || true
    [ -f "$IMG_TS/disk.img" ] && [ -f "$IMG_WG/disk.img" ] && [ -f "$IMG_LG/disk.img" ]
}

# ---- the WireGuard guest ----------------------------------------------------------------------------

# part_wg: wg0 up next to Tailscale: both zones, the routes of both, nothing of one in the way of the other
part_wg() {
    # shellcheck disable=SC2034 # read by vm_init in lib.sh
    IMAGE=$IMG_WG
    vm_init wg
    vm_start
    must "wg guest boots to the end of its init scripts" vm_wait_ready
    gcheck "wg0 is up with the profile's address and peer, and the route to its allowed IPs (R31, R32)" \
        'i=0; until ip link show wg0 | grep -q "<.*UP"; do i=$((i + 1)); [ $i -lt 40 ] || exit 1; sleep 1; done
         ip -4 addr show wg0 | grep -q "inet 10.77.0.2" &&
         wg show wg0 peers | grep -qx "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAE=" &&
         ip route | grep -q "^10.77.0.0/24 dev wg0"'
    gcheck "both zones exist: vpn with wg0, tailscale with tailscale0 only (R64a)" \
        '[ "$(uci get firewall.vpn.network)" = wg0 ] && [ "$(uci get firewall.tailscale.network)" = tailscale ] &&
         ip link show tailscale0 >/dev/null &&
         nft list chain inet fw4 input_vpn >/dev/null && nft list chain inet fw4 input_tailscale >/dev/null'
    gcheck "forwardings: vpn to lan and tailscale to lan, nothing from lan into either (R31a, D137)" \
        'nft list chain inet fw4 forward_vpn | grep -q "jump accept_to_lan" &&
         nft list chain inet fw4 forward_tailscale | grep -q "jump accept_to_lan" &&
         ! nft list chain inet fw4 forward_lan | grep -q -E "vpn|tailscale"'
    gcheck "routes do not collide: default stays on wwan0, wg0 has its /24, table 52 holds nothing of wg0" \
        'ip route get 8.8.8.8 | grep -q "dev wwan0" && ip route get 10.77.0.9 | grep -q "dev wg0" &&
         [ "$(ip route | grep -c "^default")" = 1 ] && ip rule | grep -q "lookup 52" &&
         ! ip route show table 52 | grep -q "10.77." && ! ip route | grep -q "100.64.0.0/10"'
    gcheck "Tailscale is not added and wwan is up next to the tunnel (R63e)" \
        'i=0; until [ "$(lw-tailscale status 2>/dev/null | sed -n "s/^state=//p")" = not_added ]; do
             i=$((i + 1)); [ $i -lt 90 ] || exit 1; sleep 1; done
         ubus call network.interface.wwan status | jsonfilter -e "@.up" | grep -qx true' 120
    vm_cleanup
}

# ---- the router and the LAN guest ---------------------------------------------------------------------

# lan_prepare: br-lan gets the LAN guest's NIC (eth2) in place of the harness's user-net NIC, whose
# own DHCP server would make dnsmasq refuse to serve the LAN ("found already running DHCP-server")
lan_prepare() {
    vm_sh 's=$(uci show network | sed -n "s/^network\.\(@device\[[0-9]*\]\)\.name=.br-lan.\$/\1/p" | head -n1)
[ -n "$s" ] || exit 1
uci set "network.$s.ports=eth2"; uci commit network
/etc/init.d/network reload; /etc/init.d/dnsmasq restart' 60 >/dev/null &&
        vm_wait_for '[ "$(ls /sys/class/net/br-lan/brif)" = eth2 ] && netstat -lnu | grep -q ":67 "' 60
}

lg_start() {
    rm -rf "$LGRUN"
    mkdir -p "$LGRUN"
    cp --reflink=auto "$IMG_LG/disk.img" "$LGRUN/disk.img"
    vm_py start --run "$LGRUN" --guest --link-role client --link-sock "$RUN/lanlink.sock" \
        >>"$LGRUN/harness.log"
    RUN=$LGRUN vm_wait_ready 120
}

part_router_boot() {
    local flags=(--link-role server --link-sock)
    # shellcheck disable=SC2034 # read by vm_init in lib.sh
    IMAGE=$IMG_TS
    vm_init
    flags+=("$RUN/lanlink.sock")
    [ "$INTERNET" != 1 ] || flags+=(--internet)
    [ "$LIVE" != 1 ] || flags+=(--xfer)
    vm_start "${flags[@]}"
    must "router guest boots to the end of its init scripts" vm_wait_ready
    note "tailscale package $(cat "$IMG_TS/ts_version"), internet in the guests: $INTERNET"
    must "br-lan has the LAN guest's NIC, dnsmasq serves DHCP" lan_prepare
}

# ---- checks that hold with and without internet ------------------------------------------------------

check_service() {
    gcheck "all uci-defaults scripts applied and removed" '[ -z "$(ls /etc/uci-defaults)" ]'
    gcheck "tailscaled and lw-tailscale run once each under procd, from the first start (R63c)" \
        'ls /etc/rc.d/S80tailscale /etc/rc.d/S81lw-tailscale >/dev/null &&
         [ "$(ps w | grep -c "[t]ailscaled --port")" = 1 ] && [ "$(ps w | grep -c "[l]w-tailscale run")" = 1 ]'
    gcheck "kernel TUN: /dev/net/tun and tailscale0 exist (R63)" \
        '[ -c /dev/net/tun ] && ip link show tailscale0 >/dev/null'
    gcheck "the state is not_added, with the LAN prefix offered and the route none (R63d, R64)" \
        'i=0; until lw-tailscale status | grep -qx "state=not_added"; do i=$((i + 1)); [ $i -lt 90 ] || exit 1; sleep 1; done
         lw-tailscale status | grep -qx "prefix=192.168.213.0/24" && lw-tailscale status | grep -qx "route=none" &&
         [ "$(lw-tailscale status | cut -d= -f1 | tr "\n" " ")" = "state name ip account expiry expiry_off route prefix updated " ]' 120
    gcheck "due says link and nothing else (R65)" '[ "$(lw-tailscale due)" = link ]'
    gcheck "the notification service has no instance without Telegram keys; lw-tailscale runs alone (R64, R38a)" \
        '[ -z "$(uci -q get lonewrt.notify.token)" ] && [ "$(ps w | grep -c "[l]w-notify")" = 0 ] &&
         [ "$(ps w | grep -c "[l]w-tailscale run")" = 1 ]'
}

# R64: the settings hold before anyone signs in; the same function checks them after a sign-in attempt
GPREFS='p=$(tailscale debug prefs); pf() { echo "$p" | jsonfilter -e "$1"; }
[ "$(pf @.NetfilterMode)" = 0 ] && [ "$(pf @.CorpDNS)" = false ] && [ "$(pf @.RouteAll)" = false ] &&
[ "$(pf @.Hostname)" = lwvm-ts ] && [ "$(pf "@.AdvertiseRoutes[*]")" = 192.168.213.0/24 ]'

check_settings() {
    gcheck "R64 in tailscale debug prefs: netfilter off, no DNS, no routes from the account, name lwvm-ts, the LAN offered" \
        "$GPREFS"
    gcheck "no nftables table of Tailscale: only the firewall's and the bench's, no iptables (R64, D136)" \
        '! nft list tables | grep -v -E "^table (inet fw4|ip lwvm)$" | grep . && ! command -v iptables'
    gcheck "/etc/config/tailscale: the daemon's output off (R63h, D156)" \
        '[ "$(uci get tailscale.settings.log_stdout)" = 0 ] && [ "$(uci get tailscale.settings.log_stderr)" = 0 ]'
    gcheck "syslog: no entry of the running daemon (R63h)" '[ "$(logread | grep -c " tailscaled\[")" = 0 ]'
    gnote 'echo "init lines of tailscaled --cleanup in syslog: $(logread | grep -c "procd: /etc/rc.d/S80tailscale")"'
    gcheck "syslog: lw-tailscale entries in ASCII, no link, no key anywhere in it (R63d, R65f)" \
        'logread | grep -q "lw-tailscale: state: not added" &&
         ! logread | grep "lw-tailscale" | LC_ALL=C grep -q "[^ -~]" &&
         ! logread | grep -q -i -E "login\.tailscale\.com/a/|tskey-"'
}

check_firewall() {
    gcheck "zone tailscale in uci: input ACCEPT, output REJECT, forward REJECT, MSS fix, tailscale0 only (R64a)" \
        '[ "$(uci get firewall.tailscale.input)" = ACCEPT ] && [ "$(uci get firewall.tailscale.output)" = REJECT ] &&
         [ "$(uci get firewall.tailscale.forward)" = REJECT ] && [ "$(uci get firewall.tailscale.mtu_fix)" = 1 ] &&
         [ "$(uci get firewall.tailscale.network)" = tailscale ] && [ "$(uci get network.tailscale.device)" = tailscale0 ] &&
         [ "$(uci get firewall.tailscale_lan.src)" = tailscale ] && [ "$(uci get firewall.tailscale_lan.dest)" = lan ] &&
         [ "$(uci show firewall | grep -c -E "^firewall\.[^.]+\.(src|dest)=.tailscale.$")" = 1 ]'
    gcheck "nftables: input accepted, output and forward rejected, forward to lan, MSS fix both ways (R64a, D149)" \
        'c() { nft list chain inet fw4 "$1"; }
         c input | grep -q "iifname \"tailscale0\" jump input_tailscale" &&
         c output | grep -q "oifname \"tailscale0\" jump output_tailscale" &&
         c forward | grep -q "iifname \"tailscale0\" jump forward_tailscale" &&
         c input_tailscale | grep -q "jump accept_from_tailscale" &&
         c accept_from_tailscale | grep -q "iifname \"tailscale0\".*accept" &&
         c output_tailscale | grep -q "jump reject_to_tailscale" &&
         c forward_tailscale | grep -q "jump accept_to_lan" && c forward_tailscale | grep -q "jump reject_to_tailscale" &&
         c reject_to_tailscale | grep -q "oifname \"tailscale0\".*jump handle_reject" &&
         c mangle_forward | grep -q "iifname \"tailscale0\".*maxseg size set rt mtu" &&
         c mangle_postrouting | grep -q "oifname \"tailscale0\".*maxseg size set rt mtu"'
    gcheck "nothing passes from lan, wan or vpn into the zone (R64a, D137)" \
        'for z in lan wan vpn; do
             for ch in input forward output; do
                 ! nft list chain inet fw4 ${ch}_$z | grep -q tailscale || { echo "${ch}_$z"; exit 1; }
             done
         done'
    gcheck "masquerade only on tailscale to lan, only for 100.64.0.0/10; the wan zone keeps its own (R64a, D155)" \
        'nft list chain inet fw4 srcnat_lan | grep -q "ip saddr 100.64.0.0/10.*masquerade" &&
         [ "$(nft list chain inet fw4 srcnat_lan | grep -c masquerade)" = 1 ] &&
         ! nft list chain inet fw4 srcnat_tailscale 2>/dev/null | grep -q . &&
         [ "$(nft list ruleset | grep -c masquerade)" = 2 ]'
    gcheck "wg0 and vpn as in the generic image, wwan in wan and up: the tunnel rules stand (R31, R32, R63e)" \
        'z() { uci show firewall | sed -n "s/^firewall\.\([^.]*\)\.name=.$1.\$/\1/p" | head -n1; }
         wan=$(z wan); vpn=$(z vpn)
         uci get "firewall.$wan.network" | grep -qw wwan && uci get "firewall.$vpn.network" | grep -qw wg0 &&
         [ "$(uci get network.wg0.disabled)" = 1 ] && uci show firewall | grep -q "src=.vpn." &&
         ubus call network.interface.wwan status | jsonfilter -e "@.up" | grep -qx true'
}

check_lan_guest() {
    local lgip
    check "LAN guest has an address and a default route from the router's DHCP, not the harness's" \
        vm_wait_for '[ -s /tmp/dhcp.leases ]' 60
    lg_check "LAN guest: address in 192.168.213.0/24, default route and DNS via $LAN" \
        'i=0; until ip addr show eth0 | grep -q "inet 192.168.213\."; do i=$((i + 1)); [ $i -lt 40 ] || exit 1; sleep 1; done
         ip route | grep -q "^default via 192.168.213.1 " && grep -q "nameserver 192.168.213.1" /etc/resolv.conf'
    lgip=$(vm_sh 'cut -d" " -f3 /tmp/dhcp.leases | head -n1' 2>/dev/null || true)
    note "LAN guest address $lgip"
    lg_check "LAN guest pings the router" "ping -c 2 -W 2 $LAN"
    gcheck "router pings the LAN guest and its web server logs the router's LAN address as the source" \
        "ping -c 2 -W 2 $lgip >/dev/null && wget -q -O - http://$lgip/cgi-bin/probe | grep -q lwvm-lan-guest"
    lg_check "the LAN guest logged $LAN as the source of the request (what D155 gives for traffic from the account)" \
        "[ \"\$(tail -n1 /tmp/lwvm-src.log)\" = $LAN ]"
}

# R63e: Tailscale stopped and started again leaves wwan, the router and the settings as they were
check_stop_start() {
    local id0 up0 id1 up1
    id0=$(vm_sh 'cat /proc/sys/kernel/random/boot_id')
    up0=$(vm_sh 'ubus call network.interface.wwan status | jsonfilter -e "@.uptime"')
    gcheck "tailscaled stopped: the state says not_running and link says so with exit 3 (contract-BC)" \
        '/etc/init.d/tailscale stop; i=0
         until [ "$(lw-tailscale status | sed -n "s/^state=//p")" = not_running ]; do
             i=$((i + 1)); [ $i -lt 50 ] || { lw-tailscale status; exit 1; }; sleep 1; done
         out=$(lw-tailscale link); rc=$?; [ $rc = 3 ] && [ "$out" = state=not_running ] && [ -z "$(lw-tailscale due)" ]' 90
    gcheck "tailscaled started again: not_added, and the settings of R64 are set again (R64, R63d)" \
        '/etc/init.d/tailscale start; i=0
         until [ "$(lw-tailscale status | sed -n "s/^state=//p")" = not_added ]; do
             i=$((i + 1)); [ $i -lt 80 ] || { lw-tailscale status; exit 1; }; sleep 1; done
         '"$GPREFS" 120
    gcheck "syslog has one entry per change: not added, not running, not added (R63d)" \
        '[ "$(logread | grep "lw-tailscale: state:" | sed "s/.*state: //" | tr "\n" ",")" = "not added,not running,not added," ]'
    id1=$(vm_sh 'cat /proc/sys/kernel/random/boot_id')
    up1=$(vm_sh 'ubus call network.interface.wwan status | jsonfilter -e "@.uptime"')
    check "the router did not restart and wwan kept running (uptime $up0 s, then $up1 s) (R63e, D157)" \
        bash -c '[ "$1" = "$2" ] && [ "$3" -gt "$4" ]' _ "$id1" "$id0" "$up1" "$up0"
}

# R72c: the record of one-time messages and the key are in the files sysupgrade keeps
check_sysupgrade() {
    gcheck "sysupgrade -l lists /etc/tailscale/, with the record lw-sent/ (R72c)" \
        'lw-tailscale mark link && sysupgrade -l | grep -qx "/etc/tailscale/lw-sent/link" &&
         sysupgrade -l | grep -q "^/etc/tailscale/tailscaled.state$"; rc=$?; rm -rf /etc/tailscale/lw-sent; exit $rc'
}

# link while Tailscale gives no link (no internet): exit code and output as they are
check_link_without_link() {
    if [ "$INTERNET" = 1 ]; then
        wan_link off
        sleep 3
    fi
    gshow "link with no internet and no link held: answers within 30 s (R65a); exit and output as they are" \
        't=$(date +%s); lw-tailscale link >/tmp/lwvm-l.out 2>&1; rc=$?; d=$(( $(date +%s) - t ))
         echo "exit $rc after $d s: $(tr "\n" "|" </tmp/lwvm-l.out)"; [ $d -le 30 ] && [ $rc = 3 ] &&
         [ "$(cat /tmp/lwvm-l.out)" = state=not_added ]' 60
    if [ "$INTERNET" = 1 ]; then
        wan_link on
        check "internet is back" vm_wait_for 'ping -c 1 -W 2 8.8.8.8 >/dev/null' 60
    fi
}

mode1_skips() {
    skip "link: a https://login.tailscale.com/a/... link in 25 s (needs the internet in the guest)"
    skip "R64 after a sign-in attempt, the real CLI's flags and fields (needs the internet in the guest)"
    skip "refused key: the real output of up, TS_REFUSED_RE, key marked used (needs the internet in the guest)"
    skip "key with no internet: the real output of up, key not marked used, the try returns (needs the internet)"
}

# ---- LWVM_INTERNET=1 ----------------------------------------------------------------------------------

# a link of Tailscale reaches a file in the guest only; what is checked is its shape (R65a, R65e)
check_link_online() {
    check "the guest reaches Tailscale's servers (DNS)" \
        vm_wait_for 'nslookup login.tailscale.com 127.0.0.1 >/dev/null' 60
    gshow "link: one https://login.tailscale.com/a/ line, exit 0, within 25 s (R65a, R65e)" \
        't=$(date +%s); lw-tailscale link >/tmp/lwvm-l.out 2>/tmp/lwvm-l.err; rc=$?; d=$(( $(date +%s) - t ))
         echo "exit $rc after $d s, lines: $(wc -l </tmp/lwvm-l.out), stderr bytes: $(wc -c </tmp/lwvm-l.err)"
         grep -q -E "^https://login\.tailscale\.com/a/[A-Za-z0-9]+\$" /tmp/lwvm-l.out && [ $rc = 0 ] && [ $d -le 25 ] &&
         [ "$(wc -l </tmp/lwvm-l.out)" = 1 ]' 60
    gcheck "the link is the one the daemon holds (status AuthURL), and nobody signed in: still NeedsLogin" \
        '[ "$(tailscale status --json | jsonfilter -e "@.AuthURL")" = "$(cat /tmp/lwvm-l.out)" ] &&
         [ "$(tailscale status --json | jsonfilter -e "@.BackendState")" = NeedsLogin ]'
    gcheck "the settings of R64 survive the sign-in attempt of link (D154)" "$GPREFS"
    gcheck "due still says link, no link or key in the state file or syslog (R65, R65f)" \
        '[ "$(lw-tailscale due)" = link ] && ! grep -q http /tmp/lw-tailscale/state &&
         ! logread | grep -q -i -E "login\.tailscale\.com/a/|tskey-"'
    gcheck "a second link is a new one (D140)" \
        'cp /tmp/lwvm-l.out /tmp/lwvm-l1.out; lw-tailscale link >/tmp/lwvm-l.out && ! cmp -s /tmp/lwvm-l.out /tmp/lwvm-l1.out'
    gshow "the CLI: status --json fields in NeedsLogin, exit codes of the commands the service runs" \
        'j=$(tailscale status --json); echo "status --json exit $?"
         for f in BackendState AuthURL Self.DNSName Self.TailscaleIPs Self.KeyExpiry Self.PrimaryRoutes CurrentTailnet.Name; do
             ty=$(echo "$j" | jsonfilter -t "@.$f" 2>/dev/null); echo "$f: ${ty:-absent}"; done
         tailscale status >/dev/null 2>&1; echo "plain status exit $? (not used)"' 30
    gshow "the CLI: set --advertise-routes= clears the offer, and the service sets it again (R64)" \
        'tailscale set --advertise-routes=; echo "set empty exit $?"
         echo "AdvertiseRoutes now: [$(tailscale debug prefs | jsonfilter -e "@.AdvertiseRoutes[*]")]"
         /etc/init.d/lw-tailscale restart; i=0
         until [ "$(tailscale debug prefs | jsonfilter -e "@.AdvertiseRoutes[*]")" = 192.168.213.0/24 ]; do
             i=$((i + 1)); [ $i -lt 40 ] || exit 1; sleep 1; done; echo "offer back after $i s"' 90
    gshow "the CLI: a bare tailscale up after the settings (D154)" \
        'tailscale up --timeout=3s >/tmp/lwvm-b.out 2>&1; echo "bare up exit $?"; head -n 4 /tmp/lwvm-b.out'
}

# the real up with a key Tailscale does not know, and the real up with no internet
check_key_outputs() {
    gshow "the CLI: up --auth-key=file: with a key Tailscale refuses: output, exit, TS_REFUSED_RE (R66a)" \
        'umask 077; echo '"$FAKE_KEY"' >/tmp/lwvm-key
         t=$(date +%s); timeout 40 tailscale up --auth-key=file:/tmp/lwvm-key --timeout=25s '"$TS_FLAGS"' >/tmp/lwvm-u.out 2>&1
         rc=$?; echo "exit $rc after $(( $(date +%s) - t )) s, output:"; cat /tmp/lwvm-u.out
         re=$(sed -n "s/^TS_REFUSED_RE=.\(.*\).\$/\1/p" /usr/sbin/lw-tailscale); echo "regexp: $re"
         [ -n "$re" ] && [ $rc != 0 ] && grep -q -i -E "$re" /tmp/lwvm-u.out' 60
}

check_key_service() {
    # the link goes down first: with the internet up, the service would use the key at once
    wan_link off
    sleep 3
    gcheck "fresh record, key file in place readable by root only" \
        'rm -rf /etc/tailscale/lw-sent; umask 077; echo '"$FAKE_KEY"' >/etc/tailscale/lw-authkey
         ls -l /etc/tailscale/lw-authkey | grep -q "^-rw------- "'
    gshow "no internet with a key: up's output and exit, which TS_REFUSED_RE does not match (R66a)" \
        'umask 077; echo '"$FAKE_KEY"' >/tmp/lwvm-key
         timeout 40 tailscale up --auth-key=file:/tmp/lwvm-key --timeout=25s '"$TS_FLAGS"' >/tmp/lwvm-o.out 2>&1
         rc=$?; echo "exit $rc, output:"; cat /tmp/lwvm-o.out
         re=$(sed -n "s/^TS_REFUSED_RE=.\(.*\).\$/\1/p" /usr/sbin/lw-tailscale)
         [ $rc != 0 ] && ! grep -q -i -E "$re" /tmp/lwvm-o.out' 60
    gcheck "service restarted with no internet: after a pass the key file is there, no key-used, due is empty (R66a)" \
        '/etc/init.d/lw-tailscale restart; sleep 45
         [ -f /etc/tailscale/lw-authkey ] && [ ! -e /etc/tailscale/lw-sent/key-used ] && [ -z "$(lw-tailscale due)" ] &&
         [ "$(lw-tailscale status | sed -n "s/^state=//p")" = not_added ]' 90
    wan_link on
    check "internet is back" vm_wait_for 'ping -c 1 -W 2 8.8.8.8 >/dev/null' 60
    gcheck "the try returns when the internet is back: the key is refused and marked used, its file is gone (R66a, R66b)" \
        'i=0; until [ "$(cat /etc/tailscale/lw-sent/key-used 2>/dev/null)" = refused ]; do
             i=$((i + 1)); [ $i -lt 150 ] || { ls /etc/tailscale /etc/tailscale/lw-sent; exit 1; }; sleep 1; done
         [ ! -e /etc/tailscale/lw-authkey ]' 200
    gcheck "due says refused, then nothing after mark; the state is still not_added (R65, R66a)" \
        '[ "$(lw-tailscale due)" = refused ] && lw-tailscale mark refused && [ -z "$(lw-tailscale due)" ] &&
         [ "$(lw-tailscale status | sed -n "s/^state=//p")" = not_added ]'
    gcheck "service restarted with the key file back: no second try, the file stays (R66a, D141)" \
        '/etc/init.d/lw-tailscale restart; umask 077; echo '"$FAKE_KEY"' >/etc/tailscale/lw-authkey; sleep 45
         [ -f /etc/tailscale/lw-authkey ] && [ "$(cat /etc/tailscale/lw-sent/key-used)" = refused ]; rc=$?
         rm -f /etc/tailscale/lw-authkey; exit $rc' 90
    gcheck "no key and no link in syslog or the persistent log" \
        '! logread | grep -q -i -E "login\.tailscale\.com/a/|tskey-" && ! grep -q -i -E "login\.tailscale\.com/a/|tskey-" /root/openwrt.log'
}

mode2_checks() {
    check_link_online
    check_key_outputs
    check_stop_start
    check_key_service
    gcheck "R64 holds after everything above (netfilter off, no DNS, no routes, name, LAN offered)" "$GPREFS"
}

# ---- LWVM_TS_LIVE=1 -----------------------------------------------------------------------------------

lr() { printf '%s\n' "$*" >>"$LIVE_REPORT"; }
lr_step() { echo "LWVM-TS-STEP $1"; lr "== $1"; }

# live_link: a link into $RUN/ts-link.txt through the unlogged UART, in a 0600 file, never printed
live_link() {
    local f=$RUN/ts-link.txt
    vm_py recv --run "$RUN" --out "$f" --timeout 60 >>"$RUN/harness.log" &
    local rp=$!
    sleep 1
    gcheck "link reaches the 0600 file (exit 0)" \
        'lw-tailscale link >/tmp/lwvm-l.out; rc=$?; cat /tmp/lwvm-l.out >/dev/ttyS2; rm -f /tmp/lwvm-l.out; exit $rc'
    wait "$rp" || true
    if [ -s "$f" ] && [ "$(stat -c %a "$f")" = 600 ]; then
        echo "LWVM-TS-LINK-READY $f"
        lr "link written to $f at $(date +%H:%M:%S)"
    else
        FAILS=$((FAILS + 1))
        echo "  FAIL  no link in $f"
    fi
}

# live_wait_state STATE: until lw-tailscale status says STATE, or LWVM_TS_WAIT_S passed
live_wait_state() {
    vm_wait_for "[ \"\$(lw-tailscale status | sed -n 's/^state=//p')\" = $1 ]" "$WAIT_S"
}

live_report_fields() {
    local f=$RUN/live-fields.txt
    vm_py recv --run "$RUN" --out "$f" --end LWVM-XFER-END --timeout 60 >>"$RUN/harness.log" &
    local rp=$!
    sleep 1
    vm_sh 'j=$(tailscale status --json); jf() { echo "$j" | jsonfilter -e "$1" | tr "\n" " "; }
{ echo "name: $(jf @.Self.DNSName)"; echo "ips: $(jf "@.Self.TailscaleIPs[*]")"
  echo "account: $(jf @.CurrentTailnet.Name)"; echo "keyexpiry: $(jf @.Self.KeyExpiry)"
  echo "primaryroutes: $(jf "@.Self.PrimaryRoutes[*]")"; echo "allowedips: $(jf "@.Self.AllowedIPs[*]")"
  echo "backend: $(jf @.BackendState)"; echo "every key name in the JSON:"
  echo "$j" | grep -o "\"[A-Za-z]*\":" | sort -u | tr -d "\":" | tr "\n" " "; echo
  echo "lw-tailscale status:"; lw-tailscale status; echo "lw-tailscale due: $(lw-tailscale due | tr "\n" " ")"
  echo LWVM-XFER-END; } >/dev/ttyS2' 60 >/dev/null || true
    wait "$rp" || true
    if [ -s "$f" ]; then
        cat "$f" >>"$LIVE_REPORT"
        rm -f "$f"
    fi
}

live_steps() {
    LIVE_REPORT=$RUN/live-report.txt
    (umask 077 && : >"$LIVE_REPORT")
    gcheck "fresh record for the live run" 'rm -rf /etc/tailscale/lw-sent /etc/tailscale/lw-authkey; lw-tailscale status >/dev/null'
    live_link
    if ! live_wait_state added; then
        skip "added: nobody signed in within $WAIT_S s; the steps after it need a sign-in"
        lr "SKIP: not added within $WAIT_S s, nothing after the sign-in was checked"
        return 0
    fi
    lr_step added
    live_report_fields
    check "due says added, no route message while the route is not approved (R65, R67a)" \
        vm_sh '[ "$(lw-tailscale due | grep -c "^added$")" = 1 ] && ! lw-tailscale due | grep -qx route &&
               ! lw-tailscale status | grep -qx route=approved'
    live_ping_steps
    live_route_step
    live_hold
    live_rejoin
}

live_ping_steps() {
    if [ -z "$PEER" ]; then
        skip "ping to LWVM_TS_PEER from the router and from the LAN guest (LWVM_TS_PEER not set)"
        lr "SKIP: LWVM_TS_PEER not set"
        return 0
    fi
    gcheck "the router's own ping to the owner's device does not pass: output rejected (D149, R64a)" \
        "ip route get $PEER | grep -q 'dev tailscale0' && ! ping -c 2 -W 2 $PEER >/dev/null 2>&1 &&
         nft list chain inet fw4 reject_to_tailscale | grep -q 'counter packets [1-9]'"
    # without that route the guest's ping would leave by wwan and reach the peer through the host's own Tailscale
    local before=$FAILS
    gcheck "the router routes the owner's device over tailscale0" "ip route get $PEER | grep -q 'dev tailscale0'"
    [ "$FAILS" = "$before" ] || return 0
    lg_check "the LAN guest's ping to the owner's device does not pass: nothing from lan into the zone (R64a)" \
        "! ping -c 2 -W 2 $PEER >/dev/null 2>&1"
    lr "ping $PEER: router and LAN guest both got no answer"
}

live_route_step() {
    if [ "${LWVM_TS_WAIT_ROUTE:-0}" != 1 ]; then
        skip "route approval (LWVM_TS_WAIT_ROUTE is not 1)"
        return 0
    fi
    if vm_wait_for 'lw-tailscale status | grep -qx route=approved' "$WAIT_S"; then
        lr_step route-approved
        check "due says route once the route is approved (R67a)" \
            vm_sh 'lw-tailscale due | grep -qx route'
    else
        skip "route not approved within $WAIT_S s"
        lr "SKIP: route not approved within $WAIT_S s"
    fi
}

# live_hold: the person's steps from a laptop (LuCI and SSH by name, a LAN device through the route)
# happen now; the guests stay up until $RUN/done exists or LWVM_TS_HOLD_S passed
live_hold() {
    local end=$((SECONDS + HOLD_S))
    LG_N0=$(lg_count)
    lr_step hold
    echo "LWVM-TS-HOLD create $RUN/done when the laptop steps are finished"
    while [ ! -e "$RUN/done" ] && [ "$SECONDS" -lt "$end" ]; do sleep 5; done
    if [ ! -e "$RUN/done" ]; then
        skip "hold: no $RUN/done within $HOLD_S s"
        return 0
    fi
    lr_step "done"
    live_source_check
}

# lg_count: requests the LAN guest's web server has logged so far
lg_count() {
    lg_sh 'if [ -f /tmp/lwvm-src.log ]; then wc -l </tmp/lwvm-src.log; else echo 0; fi' | tr -d ' \r'
}

live_source_check() {
    local n
    n=$(($(lg_count) - LG_N0))
    if [ "$n" -le 0 ]; then
        skip "the LAN guest's web log has no new request (a LAN device opened through the route, D155)"
        return 0
    fi
    lg_check "every request in the LAN guest's log came from the router's LAN address $LAN, none from 100.x (D155)" \
        "! grep -v -x $LAN /tmp/lwvm-src.log | grep -q ."
    lr "LAN guest saw $n requests, all from $LAN"
}

live_rejoin() {
    if [ "${LWVM_TS_REJOIN:-0}" != 1 ]; then
        skip "end of sign-in and a second sign-in (LWVM_TS_REJOIN is not 1)"
        return 0
    fi
    lr_step wait-ended
    echo "LWVM-TS-HINT remove this router in the Tailscale admin page now"
    if ! live_wait_state ended; then
        skip "the router was not removed within $WAIT_S s"
        lr "SKIP: still added after $WAIT_S s"
        return 0
    fi
    lr_step ended
    check "due says expired (R68a)" vm_sh '[ "$(lw-tailscale due | tr "\n" " ")" = "expired " ]'
    lr_step rejoin-link
    live_link
    if live_wait_state added; then
        lr_step rejoined
        check "a new sign-in starts a new round: due says added again (R72b)" \
            vm_sh 'lw-tailscale due | grep -qx added'
    else
        skip "no second sign-in within $WAIT_S s"
    fi
}

# ---- main ---------------------------------------------------------------------------------------------

main() {
    build_images || {
        echo "  FAIL  the images (see $VMWORK/logs/ts-render-*.log and ts-image-*.log)"
        exit 1
    }
    echo "  ok    images: tailscale router, WireGuard variant and LAN guest (the x86 package from the feed)"
    part_wg
    part_router_boot
    lg_start
    check_service
    check_settings
    check_firewall
    check_lan_guest
    check_link_without_link
    if [ "$INTERNET" = 1 ]; then
        mode2_checks
    else
        mode1_skips
        check_stop_start
    fi
    check_sysupgrade
    if [ "$LIVE" = 1 ]; then live_steps; else skip "live sign-in steps (LWVM_TS_LIVE is not 1)"; fi
    note "$SKIPS steps reported SKIP"
    finish
}

# sourced (a dry run of the live steps against a stand-in CLI) runs nothing
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main; fi
