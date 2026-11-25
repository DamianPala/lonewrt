#!/usr/bin/env bash
# The LAN stops advertising a dead IPv6 default (SPEC R74c, R74f, R49i, D175, D198, D216) with the real
# netifd, odhcpd, the image's lan6.sh and init script and, for the last part, the real lw-linkwatch.
# One guest, the router, with the stand-in protocol `lwvm` (dual-stack session: native IPv4 and an
# IPv6 call with a /64 and a source-specific default route, as the modem's report gives them). The
# LAN link is captured by tests/vm/lan-ra-peer.py on the host: every router advertisement the router
# sends on br-lan is one line with its router lifetime and the lifetimes of its prefixes. A second
# IPv6 default route (what a wired wan6 or a WireGuard `::/0` is) is added on the harness's own NIC.
#
#   tests/vm/96-lan6.sh
#
# What the lines look like, measured with the odhcpd of OpenWrt 25.12.6 (see SPEC R74c):
#   served:       lifetime=1800, the prefix with pref=1800
#   loss seen by netifd (the LAN address is deprecated): a withdrawal advertisement with the prefix
#                 pref=0 valid=0 (lifetime 1800 while another default exists, else 0), then the final
#                 advertisement lifetime=0 without a prefix, then nothing
#   loss seen by the watcher only (the address is not deprecated): the same, with pref=60 (the floor
#                 of odhcpd's max_preferred_lifetime)
# shellcheck disable=SC2016 # guest scripts expand in the guest
# shellcheck disable=SC2329 # scenarios pass callbacks to must/check and the EXIT trap
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck disable=SC2034 # read by lib.sh (run directory, the closing line)
SCENARIO=lan6

PEER_PID=
MARK=0
RALOG=
STUB_UQMI=$FW/tests/linkwatch/stubs/uqmi

cl_cleanup() {
    vm_cleanup
    [ -z "$PEER_PID" ] || { kill "$PEER_PID" 2>/dev/null || true; wait "$PEER_PID" 2>/dev/null || true; }
}
trap cl_cleanup EXIT

# ---- the capture ------------------------------------------------------------------------------------

# ra_mark: the advertisements seen from now on are the ones of the next step
ra_mark() { MARK=$(wc -l <"$RALOG"); }
ra_new() { tail -n +$((MARK + 1)) "$RALOG"; }
ra_count() { ra_new | wc -l | tr -d ' '; }
ra_last() { ra_new | tail -n 1; }
rs() { : >"$RUN/peer/rs"; }

# rs_sent: how many solicitations the peer has put on the wire (it counts them in rs.sent)
rs_sent() { wc -l <"$RUN/peer/rs.sent" 2>/dev/null || echo 0; }

# ra_quiet SECONDS: the router solicited every 2 s answers with nothing, and sends nothing of its own.
# Silence proves nothing from a dead peer, so the peer must be running and must have sent the
# solicitations (one per 2 s, less one for the last still unsent).
ra_quiet() {
    local end=$((SECONDS + $1)) s0 want
    ra_mark
    s0=$(rs_sent)
    while [ "$SECONDS" -lt "$end" ]; do
        kill -0 "$PEER_PID" 2>/dev/null || { echo "the capture peer is not running"; return 1; }
        rs
        sleep 2
    done
    sleep 1
    want=$((($1 / 2) - 1))
    [ "$(($(rs_sent) - s0))" -ge "$want" ] ||
        { echo "the peer sent $(($(rs_sent) - s0)) solicitations, expected at least $want"; return 1; }
    [ "$(ra_count)" = 0 ] || { ra_new; return 1; }
}

# ra_final_seen: the final advertisement (router lifetime 0, no prefix option) is among the new ones
ra_final_seen() { ra_new | awk '/RA lifetime=0 / && !/pio=/ { f = 1 } END { exit !f }'; }

# wd_wait SECONDS: the final advertisement of a withdrawal comes within SECONDS, whatever other
# advertisements the step produced before it; then the rest of the window gets time to show up
wd_wait() {
    local end=$((SECONDS + $1))
    while [ "$SECONDS" -lt "$end" ]; do
        ra_final_seen && { sleep 2; return 0; }
        sleep 1
    done
    ra_new
    gnote 'logread | grep -E "odhcpd|lan6" | tail -n 8; sed -n "/config dhcp .lan/,/config dhcp .wan/p" /var/run/lw-odhcpd/dhcp | grep -E "ra|lifetime"'
    return 1
}

# wd_window: the advertisements since the mark hold, in this order, the withdrawal advertisement (the
# old prefix with a preferred lifetime of at most 60 s) and the final one (router lifetime 0, no
# prefix option), 1 to 5 s apart (odhcpd's 1 s delay after a reload and the 3 s wait of the init
# script, measured about 2 s), and nothing after the final one. Advertisements before the
# withdrawal are not part of the window. Prints the gap.
wd_window() {
    ra_new | awk '
        !w && /pio=[^ ]+ pref=([0-9]|[1-5][0-9]|60) / { w = 1; tw = $1; next }
        !w { next }
        !f && /RA lifetime=0 / && !/pio=/ { f = 1; tf = $1; next }
        { printf "unexpected advertisement %s the final one: %s\n", (f ? "after" : "before"), $0; bad = 1 }
        END {
            if (!w) { print "no withdrawal advertisement"; exit 1 }
            if (!f) { print "no final advertisement"; exit 1 }
            gap = tf - tw
            printf "gap %.1f s\n", gap
            if (bad || gap < 1 || gap > 5) exit 1
        }'
}

# a new advertisement that has lifetime=N (any), and one with a prefix of at most/at least pref seconds
ra_has() { ra_new | grep -Eq -- "$1"; }
ra_lifetime_zero_last() { ra_last | grep -q '^ *[0-9.]* RA lifetime=0 '; }
ra_final_has_no_prefix() { ! ra_last | grep -q 'pio='; }

# ---- the router ------------------------------------------------------------------------------------

# wwan_mode v4|dual: the stand-in protocol's session, applied by a reload of the network
wwan_mode() {
    vm_sh "uci set network.wwan.mode='$1'; uci commit network; /etc/init.d/network reload" 60 >/dev/null
}
# new_session: the same session again, from nothing
new_session() { vm_sh 'ifdown wwan; sleep 2; ifup wwan' 60 >/dev/null; }

# lan_prepare: br-lan gets the NIC of the capture (eth2) in place of the harness's user-net NIC
lan_prepare() {
    vm_sh 's=$(uci show network | sed -n "s/^network\.\(@device\[[0-9]*\]\)\.name=.br-lan.\$/\1/p" | head -n1)
[ -n "$s" ] || exit 1
uci set "network.$s.ports=eth2"; uci commit network
/etc/init.d/network reload; /etc/init.d/dnsmasq restart' 60 >/dev/null &&
        vm_wait_for '[ "$(ls /sys/class/net/br-lan/brif)" = eth2 ]' 60
}

# second_default on|off: another IPv6 default route, through the harness's own NIC (not a wwan device)
second_default() {
    if [ "$1" = on ]; then
        vm_sh 'ip link set eth0 up; ip -6 addr replace 2001:db8:99::2/64 dev eth0 nodad
ip -6 route replace default via 2001:db8:99::1 dev eth0 metric 100' 30
    else
        vm_sh 'ip -6 route del default via 2001:db8:99::1 dev eth0 2>/dev/null; ip -6 addr flush dev eth0 scope global; true' 30
    fi
}

wwan_dual_up() {
    vm_wait_for 's=$(ubus call network.interface.wwan status) &&
        [ "$(echo "$s" | jsonfilter -e "@.up")" = true ] &&
        echo "$s" | jsonfilter -e "@.data.cid_6" | grep -qx 18' 60
}

# served: the LAN is served: an advertisement with a router lifetime above zero, a prefix with a
# preferred lifetime above 60 s and the RDNSS option (R74a)
served() {
    local end=$((SECONDS + 45)) l
    while [ "$SECONDS" -lt "$end" ]; do
        rs
        sleep 2
        l=$(ra_last)
        case $l in
            *"RA lifetime=1800 "*"pio=2001:db8:64:100::/64 pref=1800 "*"rdnss="*) return 0 ;;
        esac
    done
    return 1
}

# ---- the scenario ----------------------------------------------------------------------------------

mkdir -p "$VMWORK/logs"
lock=()
[ -z "${LWVM_BUILD_LOCK:-}" ] || lock=(flock "$LWVM_BUILD_LOCK")
# run-all.sh builds the image of this tree (or of its --overlay) once and hands it over in
# LWVM_IMAGE_DIR; started alone, the scenario builds its own
if [ -f "${LWVM_IMAGE_DIR:-/nonexistent}/disk.img" ]; then
    IMG=$LWVM_IMAGE_DIR
    echo "  ok    image of the runner ($IMG)"
else
    IMG=$(LWVM_NO_CURRENT=1 "${lock[@]}" "$VMDIR/build-image.sh" 2>"$VMWORK/logs/lan6-image.log" | tail -n1) || true
    [ -f "$IMG/disk.img" ] || { echo "  FAIL  image build (see $VMWORK/logs/lan6-image.log)"; exit 1; }
    echo "  ok    image build (the render of this tree)"
fi
# shellcheck disable=SC2034 # read by vm_init in lib.sh
IMAGE=$IMG
vm_init
mkdir -p "$RUN/peer"
RALOG=$RUN/peer/ra.log
: >"$RALOG"
python3 -I "$VMDIR/lan-ra-peer.py" --sock "$RUN/lanlink.sock" --ctl "$RUN/peer" --log "$RALOG" \
    >"$RUN/peer/peer.out" 2>&1 &
PEER_PID=$!
vm_start --link-role server --link-sock "$RUN/lanlink.sock"
must "router boots to the end of its init scripts" vm_wait_ready
note "odhcpd: $(grep -E '^odhcpd' "$IMG/manifest" | tr '\n' ' ')"
must "br-lan has the NIC of the capture" lan_prepare
must "the stand-in protocol replaces qmi on wwan, dual stack" vm_sh \
    'uci set network.wwan.proto=lwvm; uci -q delete network.lwvm_default; uci set network.wwan.mode=dual; uci commit network
/etc/init.d/network reload' 60
must "wwan is up with the IPv4 and the IPv6 call" wwan_dual_up
gcheck "odhcpd reads the RAM copy of the image (R74g)" 'ps w | grep -q "[o]dhcpd -c /var/run/lw-odhcpd"'
must "R74a: the LAN is served: lifetime 1800, the prefix with pref=1800, RDNSS" served

echo "# loss seen by netifd, another IPv6 default exists (R74c)"
must "a second IPv6 default route is present" second_default on
gcheck "the router has two IPv6 defaults" '[ "$(ip -6 route show default | wc -l)" = 2 ]'
ra_mark
must "the session ends (wwan restarts without IPv6)" wwan_mode v4
must "the withdrawal and the final advertisement follow" wd_wait 40
note "advertisements of the loss:$(ra_new | sed 's/^/\n          /')"
check "R74c: the withdrawal and then the final advertisement, 1 to 5 s apart, nothing else in between" wd_window
check "R74c: the last advertisement has router lifetime 0 although another default exists" ra_lifetime_zero_last
check "R74c: and no prefix option" ra_final_has_no_prefix
check "R74c: an advertisement before it carries the old prefix with preferred lifetime 0" \
    ra_has 'pio=2001:db8:64:100::/64 pref=0 '
check "R74c: then no advertisement, also when solicited" ra_quiet 8
gcheck "R74b: at most two odhcpd warnings about the default route for this loss" \
    '[ "$(logread | grep -c "odhcpd.*default route")" -le 2 ]'

echo "# the prefix is back"
ra_mark
must "a new session with IPv6" wwan_mode dual
must "wwan is up with both calls again" wwan_dual_up
must "R74c: the advertisements start again: lifetime 1800, the prefix preferred" served

echo "# loss seen by the watcher only, another IPv6 default exists (R74f flag, R74c)"
ra_mark
gcheck "the flag of the watcher for this session switches the LAN off" \
    'mkdir -p /var/run/lw-linkwatch; chmod 700 /var/run/lw-linkwatch
echo "18/19 -" >/var/run/lw-linkwatch/v6lost; /etc/init.d/odhcpd reload lan6' 60
must "the withdrawal and the final advertisement follow" wd_wait 40
note "advertisements of the loss:$(ra_new | sed 's/^/\n          /')"
check "R74c: the withdrawal and then the final advertisement, 1 to 5 s apart, nothing else in between" wd_window
check "R74c: the last advertisement has router lifetime 0 although another default exists" ra_lifetime_zero_last
check "R74c: and no prefix option" ra_final_has_no_prefix
check "R74c: the one before it carries the prefix with a preferred lifetime of at most 60 s" \
    ra_has 'RA lifetime=[1-9][0-9]* .*pio=2001:db8:64:100::/64 pref=([0-9]|[1-5][0-9]|60) '
check "R74c: then none" ra_quiet 8
ra_mark
gcheck "the flag goes: the LAN follows the session again" \
    'rm -f /var/run/lw-linkwatch/v6lost; /etc/init.d/odhcpd reload lan6' 60
must "R74c: served again" served

echo "# loss with no other IPv6 default"
must "the second default route is gone" second_default off
gcheck "one IPv6 default left" '[ "$(ip -6 route show default | wc -l)" = 1 ]'
ra_mark
must "the session ends" wwan_mode v4
must "the withdrawal and the final advertisement follow" wd_wait 40
note "advertisements of the loss:$(ra_new | sed 's/^/\n          /')"
check "R74c: the withdrawal and then the final advertisement, 1 to 5 s apart, nothing else in between" wd_window
check "R74c: the last advertisement has router lifetime 0, no prefix option" ra_lifetime_zero_last
check "R74c: the withdrawal has lifetime 0 and the old prefix with preferred lifetime 0" \
    ra_has 'RA lifetime=0 .*pio=2001:db8:64:100::/64 pref=0 '
check "R74c: then none" ra_quiet 8
must "a new session with IPv6" wwan_mode dual
must "R74c: served again" served

echo "# R74f with the real watcher (a stand-in for uqmi that models the modem's calls)"
must "a second IPv6 default route is present" second_default on
must "uqmi is the stand-in of tests/linkwatch, the control node exists" vm_sh \
    "mv /usr/bin/uqmi /usr/bin/uqmi.real; cat >/usr/bin/uqmi <<'LWVM_EOF'
$(cat "$STUB_UQMI")
LWVM_EOF
chmod 755 /usr/bin/uqmi; mkdir -p /lwtest/uqmi; echo up >/lwtest/uqmi/session; touch /wwan0
/etc/init.d/lw-linkwatch restart" 60
gcheck "the watcher reads both calls while both are up (the stand-in logs each call)" \
    'sleep 12; grep -c "wds,16" /lwtest/uqmi-calls >/dev/null && grep -c "wds,18" /lwtest/uqmi-calls >/dev/null'
gcheck "R74f: a healthy IPv6 call writes no line and no flag" \
    '[ ! -e /var/run/lw-linkwatch/v6lost ] && [ "$(logread | grep -c "lw-linkwatch:")" = 0 ]'
vm_sh 'ubus call network.interface.wwan status | jsonfilter -e "@.uptime"' | tr -d '\r' >"$RUN/wwan-uptime"

# an unreadable settings answer after a disconnected status changes nothing
vm_sh 'echo @FAIL >/lwtest/uqmi/q-settings; echo down >/lwtest/uqmi/session-18' 30 >/dev/null
ra_mark
sleep 16
gcheck "R74f: a disconnected status with unreadable settings changes nothing" \
    '[ ! -e /var/run/lw-linkwatch/v6lost ] && [ "$(logread | grep -c "lw-linkwatch:")" = 0 ]'
check "R74f: and no withdrawal reaches the LAN (no lifetime 0, no prefix with at most 60 s)" \
    bash -c '! tail -n +$(($1 + 1)) "$2" | grep -Eq "RA lifetime=0 |pref=([0-9]|[1-5][0-9]|60) "' _ "$MARK" "$RALOG"

# the confirmed loss
vm_sh 'rm -f /lwtest/uqmi/q-settings' 30 >/dev/null
must "R74f: the watcher flags the loss within a few passes" \
    vm_wait_for '[ -s /var/run/lw-linkwatch/v6lost ]' 40
must "the withdrawal and the final advertisement follow" wd_wait 40
note "advertisements of the loss:$(ra_new | sed 's/^/\n          /')"
check "R74f: the withdrawal and then the final advertisement, 1 to 5 s apart, nothing else in between" wd_window
check "R74f: the last advertisement has router lifetime 0 although another default exists" ra_lifetime_zero_last
check "R74f: and no prefix option" ra_final_has_no_prefix
check "R74f: the one before it carries the prefix with a preferred lifetime of at most 60 s" \
    ra_has 'RA lifetime=[1-9][0-9]* .*pio=2001:db8:64:100::/64 pref=([0-9]|[1-5][0-9]|60) '
check "R74f: then none" ra_quiet 8
gcheck "R74f: one line for the loss, none for IPv4" \
    '[ "$(logread | grep -c "lw-linkwatch: IPv6 call lost, IPv4 kept")" = 1 ] &&
     [ "$(logread | grep -c "lw-linkwatch: data session lost")" = 0 ]'
gcheck "R49i: IPv4 is untouched: wwan is up, the same start (its uptime grew), no ifup of the watcher" \
    'u=$(ubus call network.interface.wwan status | jsonfilter -e "@.uptime"); [ "$u" -gt '"$(cat "$RUN/wwan-uptime")"' ] &&
     ! logread | grep -q "lw-linkwatch.*ifup" && [ "$(grep -c "stop-network\|start-network" /lwtest/uqmi-calls)" = 0 ]'
gcheck "R74f: the odhcpd of the RAM copy has the server off" \
    '[ "$(uci -q -c /var/run/lw-odhcpd get dhcp.lan.ra)" = disabled ]'
# the stand-in logs every call by client: while the loss stands the watcher reads the status of the
# IPv6 call once per pass (5 s) and asks for the settings no more
gcheck "R74f: while the loss is flagged: one status read per pass (5 s), no settings read, one line in all" \
    'cnt() { grep -c -- "wds,18 $1" /lwtest/uqmi-calls || true; }
s0=$(cnt --get-data-status); g0=$(cnt --get-current-settings)
sleep 16
s1=$(cnt --get-data-status); g1=$(cnt --get-current-settings)
echo "status reads $((s1 - s0)), settings reads $((g1 - g0)) in 16 s"
[ "$((s1 - s0))" -ge 2 ] && [ "$((s1 - s0))" -le 4 ] && [ "$g1" = "$g0" ] &&
    [ "$(logread | grep -c "lw-linkwatch: IPv6 call lost")" = 1 ]'

# the call is back
ra_mark
vm_sh 'echo up >/lwtest/uqmi/session-18' 30 >/dev/null
must "R74f: the LAN is served again" served
gcheck "R74f: one line for the return, the flag is gone" \
    '[ "$(logread | grep -c "lw-linkwatch: IPv6 call connected again")" = 1 ] && [ ! -e /var/run/lw-linkwatch/v6lost ]'

vm_sh 'mv -f /usr/bin/uqmi.real /usr/bin/uqmi; rm -f /wwan0' 30 >/dev/null || true
finish
