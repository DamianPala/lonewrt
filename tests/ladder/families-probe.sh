# The family-aware round of pings (R77, R77a, R77c, D173, D185) and the operator DNS of the
# session (R18c, Terms "operator DNS"), on every kind of session: IPv4 only (what every image makes
# until the IP family rule), dual stack, IPv6 only, IPv6 with the translation wwan_6_4, and IPv6 only
# through the child wwan_6. The stand-in ping answers by family, device and address (tests/stubs/ping).
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
PATH=/fw/tests/ladder/stubs:$PATH
export PATH
lw_setup
# shellcheck source=src/files/usr/lib/lw/common.sh
. /usr/lib/lw/common.sh
# shellcheck source=src/files/usr/lib/lw/probe.sh
. /usr/lib/lw/probe.sh

V6A=2001:4860:4860::8888
V6B=2606:4700:4700::1111

# round: one round with a fresh ping log, and the syslog lines of the probe
round() {
    : >"$T/net-calls"
    : >"$T/syslog"
    rc=0
    lw_probe_round || rc=$?
}
# calls: the pings of the last round, one line per call, without the options that never change
calls() { grep '^ping ' "$T/net-calls" | sed 's/ -c 2 -w 3 -q//'; }
no_ipv6_ping() {
    ! grep -q -- ' -6 \|::' "$T/net-calls" || lw_fail "$1: a ping to IPv6: $(cat "$T/net-calls")"
}
no_ipv4_ping() {
    ! grep -q -- ' -4 \|8\.8\.8\.8\|1\.1\.1\.1' "$T/net-calls" || lw_fail "$1: a ping to IPv4: $(cat "$T/net-calls")"
}
probe_lines() { grep -c 'lw-probe: ' "$T/syslog" || :; }

# --- R77a: the IPv4-only session, with the one fixture of lw_setup (wwan_4 only), with the full
# netifd data, and with no data at all, gets no ping to an IPv6 address and no log line about IPv6
for kind in seed legacy v4 none; do
    case $kind in
        seed) ;;
        legacy) lw_session legacy ;;
        v4) lw_session v4 ;;
        none) rm -f "$T"/ifstatus/*.json ;;
    esac
    lw_reach 4 wwan0
    round
    lw_expect_eq "$rc" 0 "R77a $kind: online on IPv4"
    lw_expect_eq "$LW_P_ONLINE/$LW_P_OK4/${LW_P_OK6:-none}" "1/1/none" "R77a $kind: families"
    lw_expect_eq "$(calls)" "ping -4 -I wwan0 8.8.8.8" "R77a $kind: one ping, the first address answers"
    no_ipv6_ping "R77a $kind"
    # nothing answers: both IPv4 addresses in turn, still no IPv6, still no line in the log
    lw_reach_none
    round
    lw_expect_eq "$rc" 1 "R77a $kind: offline"
    lw_expect_eq "$LW_P_ONLINE/$LW_P_OK4/${LW_P_OK6:-none}" "0/0/none" "R77a $kind: families offline"
    lw_expect_eq "$(calls)" "ping -4 -I wwan0 8.8.8.8
ping -4 -I wwan0 1.1.1.1" "R77a $kind: both addresses of IPv4 in turn"
    no_ipv6_ping "R77a $kind, offline"
    lw_expect_eq "$(probe_lines)" 0 "R77a $kind: log lines"
    lw_reach_off
done
lw_session v4

# the second address answers when the first does not
lw_reach 4 wwan0 1.1.1.1
round
lw_expect_eq "$rc/$(calls)" "0/ping -4 -I wwan0 8.8.8.8
ping -4 -I wwan0 1.1.1.1" "R77: the second legacy address counts"
lw_reach_none

# Four unresponsive ifstatus commands must leave time for the pings (R77c).
touch "$T/ifstatus/hang"
lw_reach 4 wwan0
t0=$(date +%s)
round
elapsed=$(($(date +%s) - t0))
rm -f "$T/ifstatus/hang"
[ "$elapsed" -le 10 ] || lw_fail "R77c: hung ifstatus calls took ${elapsed}s"
lw_expect_eq "$rc/$(calls)" "0/ping -4 -I wwan0 8.8.8.8" "R77a: bounded fallback stays on wwan0"
lw_expect_eq "$(probe_lines)" 0 "R77a: a netifd timeout adds no log line"
lw_reach_none

# --- R77: dual stack, both families pinged through their own device, each stops at its first answer
lw_session dual
lw_reach 4 wwan0
lw_reach 6 wwan0
round
lw_expect_eq "$LW_P_ONLINE/$LW_P_OK4/$LW_P_OK6" "1/1/1" "R77 dual: both answer"
lw_expect_eq "$(calls)" "ping -4 -I wwan0 8.8.8.8
ping -6 -I wwan0 $V6A" "R77 dual: one ping per family"
lw_expect_eq "$(probe_lines)" 0 "R77b dual: no line while both answer"
# the second IPv6 address answers when the first does not
lw_reach_none
lw_reach 6 wwan0 $V6B
round
lw_expect_eq "$rc/$LW_P_OK4/$LW_P_OK6" "0/0/1" "R77 dual: only the second IPv6 address answers"
lw_expect_eq "$(calls)" "ping -4 -I wwan0 8.8.8.8
ping -4 -I wwan0 1.1.1.1
ping -6 -I wwan0 $V6A
ping -6 -I wwan0 $V6B" "R77c dual: four addresses at most"

# --- R77b: this slice only computes the result of each family; no round writes a line, whichever
# family is lost or back (the one owner of that state is watchcat, slice 1b)
for fam in 4 6 none both; do
    lw_session dual
    lw_reach_none
    case $fam in
        4) lw_reach 6 wwan0 ;;
        6) lw_reach 4 wwan0 ;;
        both) lw_reach 4 wwan0; lw_reach 6 wwan0 ;;
    esac
    : >"$T/syslog.prio"
    round
    lw_probe_round notify || :
    lw_probe_round || :
    lw_expect_eq "$(grep -c 'lw-probe' "$T/syslog.prio" || :)" 0 "R77b: no line for the loss of IPv$fam"
done
lw_reach_off

# --- R77a, D173: IPv6 only, no ping to an IPv4 address; through the translation, IPv4 goes over its
# own device and not over wwan0
for kind in v6 v6child; do
    lw_session "$kind"
    lw_reach 6 wwan0
    round
    lw_expect_eq "$rc/${LW_P_OK4:-none}/$LW_P_OK6" "0/none/1" "D173 $kind: online on IPv6"
    lw_expect_eq "$(calls)" "ping -6 -I wwan0 $V6A" "D173 $kind: one IPv6 ping"
    no_ipv4_ping "R77a $kind"
    lw_reach_none
    round
    lw_expect_eq "$rc/${LW_P_OK4:-none}/$LW_P_OK6" "1/none/0" "D173 $kind: offline"
    lw_expect_eq "$(calls)" "ping -6 -I wwan0 $V6A
ping -6 -I wwan0 $V6B" "D173 $kind: both IPv6 addresses"
    no_ipv4_ping "R77a $kind, offline"
    lw_expect_eq "$(probe_lines)" 0 "R77a $kind: no line about the IPv4 that is not there"
done
lw_session v6clat
lw_reach 4 464-wwan_6_4
lw_reach 6 wwan0
round
lw_expect_eq "$rc/$LW_P_OK4/$LW_P_OK6/$LW_P_XLAT" "0/1/1/1" "R76d: translated IPv4 and IPv6 answer"
lw_expect_eq "$(calls)" "ping -4 -I 464-wwan_6_4 8.8.8.8
ping -6 -I wwan0 $V6A" "R76d: IPv4 over the translation device"
# IPv6 lost, translated IPv4 answers: online
lw_reach_none
lw_reach 4 464-wwan_6_4
round
lw_expect_eq "$rc/$LW_P_OK4/$LW_P_OK6" "0/1/0" "D173: translated IPv4 alone keeps the link online"
# a ping bound to wwan0 that would work does not count for the translated IPv4 (R77)
lw_reach_none
lw_reach 4 wwan0
round
lw_expect_eq "$rc/$LW_P_OK4/$LW_P_OK6" "1/0/0" "R77: IPv4 on wwan0 is not the translation's"
# R76d: when a CLAT status lacks l3_device, device can still describe the underlying modem.
printf '{"up":true,"device":"wwan0"}\n' >"$T/ifstatus/wwan_6_4.json"
round
lw_expect_eq "$rc/$LW_P_DEV4/$LW_P_OK4" "1/464-wwan_6_4/0" "R76d: no fallback from CLAT to wwan0"

# --- Terms, R77a: the families of the session come from the call the parent published; a device
# that is not ready makes its family fail this round, it does not make the family absent
lw_session dual
printf '{"up":false}\n' >"$T/ifstatus/wwan_4.json"
lw_reach_none
lw_reach 6 wwan0
(
    # wwan-recover enables nounset and starts without any result from an earlier round.
    unset _lw_pms
    round
    lw_expect_eq "$LW_P_HAS4/$LW_P_HAS6/${LW_P_DEV4:-none}/$LW_P_DEV6" "1/1/none/wwan0" "Terms: a down wwan_4 on dual stack"
    lw_expect_eq "$rc/$LW_P_OK4/$LW_P_OK6/$LW_P_MS" "0/0/1/21.500" "Terms: IPv4 failed, IPv6 answers, online"
    lw_expect_eq "$(calls)" "ping -6 -I wwan0 $V6A" "R77a: no ping for the IPv4 that has no device"
) || lw_fail "R77: the first round must work with a non-ready family"
lw_reach_none
round
lw_expect_eq "$rc/$LW_P_OK4/$LW_P_OK6" "1/0/0" "Terms: both families failed"
# R73p: a static IPv4 on the parent also gives a dual-stack session a ready native device.
rm -f "$T/ifstatus/wwan_4.json"
cat >"$T/ifstatus/wwan.json" <<'EOF'
{
    "up":true,
    "l3_device":"wwan0",
    "data":{"cid_4":"17","pdh_4":"3203210528","cid_6":"18","pdh_6":"3203210530"},
    "ipv4-address":[{"address":"192.0.2.10"}],
    "ipv6-address":[{"address":"2001:db8::10"}]
}
EOF
lw_reach 4 wwan0
round
lw_expect_eq "$rc/$LW_P_DEV4/$LW_P_OK4/$LW_P_OK6" "0/wwan0/1/0" "R73p: the parent's static IPv4 answers"
# R77a: current IPv4-only QMI publishes the native call before its DHCP child is ready.
lw_session v4
printf '{"up":false}\n' >"$T/ifstatus/wwan_4.json"
lw_reach 4 wwan0
round
lw_expect_eq "$rc/$(calls)" "0/ping -4 -I wwan0 8.8.8.8" "R77a: keep the IPv4-only ping while DHCP is pending"
lw_reach_none
round
lw_expect_eq "$rc/$(calls)" "1/ping -4 -I wwan0 8.8.8.8
ping -4 -I wwan0 1.1.1.1" "R77a: both legacy pings while DHCP is pending and neither answers"
# an IPv6-only session whose child has no address yet: IPv6 is the session's, it failed, no IPv4 ping
for kind in v6child v6; do
    lw_session "$kind"
    case $kind in
        v6child) printf '{"up":false}\n' >"$T/ifstatus/wwan_6.json" ;;
        v6) printf '{"up":true,"l3_device":"wwan0","data":{"cid_6":"18","pdh_6":"3203210530"}}\n' >"$T/ifstatus/wwan.json" ;;
    esac
    lw_reach 4 wwan0
    lw_reach 6 wwan0
    round
    lw_expect_eq "$LW_P_HAS4/$LW_P_HAS6/${LW_P_DEV6:-none}" "0/1/none" "Terms: pending IPv6 ($kind)"
    lw_expect_eq "$rc/${LW_P_OK4:-none}/$LW_P_OK6/$LW_P_MS" "1/none/0/" "Terms: pending IPv6 failed with no RTT ($kind)"
    lw_expect_eq "$(lw_pings)" 0 "R77a: pending IPv6 ($kind): no ping at all"
done
# a translation that is there but not up: IPv4 service of the session, failed this round
lw_session v6clat
printf '{"up":false}\n' >"$T/ifstatus/wwan_6_4.json"
lw_reach_none
lw_reach 6 wwan0
round
lw_expect_eq "$LW_P_HAS4/$LW_P_XLAT/${LW_P_DEV4:-none}" "1/1/none" "Terms: a translation that is not up"
lw_expect_eq "$rc/$LW_P_OK4/$LW_P_OK6" "0/0/1" "R76d: the translation failed, IPv6 answers"
# a parent without call data uses the legacy IPv4 probe; partial data
# is read the same way, with one debug line and no info line
lw_session legacy
lw_reach_none
lw_reach 4 wwan0
LW_LOG_LEVEL=debug
: >"$T/syslog.prio"
round
lw_expect_eq "$LW_P_HAS4/$LW_P_HAS6/$LW_P_DEV4" "1/0/wwan0" "R77a: no call data, IPv4 on wwan0"
lw_expect_eq "$(grep -c 'lw-probe' "$T/syslog.prio" || :)" 0 "R77a: no call data is not malformed"
for data in '"cid_4":"17"' '"pdh_6":"3203210530"' '"cid_4":"17","pdh_4":"3203210528","cid_6":"18"'; do
    printf '{"up":true,"l3_device":"wwan0","data":{%s}}\n' "$data" >"$T/ifstatus/wwan.json"
    : >"$T/syslog.prio"
    round
    lw_expect_eq "$LW_P_HAS4/$LW_P_HAS6/$LW_P_DEV4" "1/0/wwan0" "R77a: partial call data ($data), IPv4 on wwan0"
    lw_expect_eq "$(cat "$T/syslog.prio")" "daemon.debug lw-probe: call data of wwan incomplete, read as IPv4 on wwan0" "R77a: one debug line ($data)"
    no_ipv6_ping "R77a partial data"
done
LW_LOG_LEVEL=info
: >"$T/syslog.prio"
round
lw_expect_eq "$(cat "$T/syslog.prio")" "" "R77: no info line for partial data"
lw_reach_off

# --- R77: an answer that comes over another interface is none, on every kind of session
for kind in v4 dual v6 v6clat; do
    lw_session "$kind"
    lw_reach_none
    for dev in - wg0 tailscale0 br-lan eth0; do
        lw_reach 4 "$dev"
        lw_reach 6 "$dev"
    done
    round
    lw_expect_eq "$rc/$LW_P_ONLINE" "1/0" "R77 $kind: the tunnel, the LAN and an unbound ping do not count"
    ! grep -q -- ' -I -\| -I wg0\| -I tailscale0\| -I br-lan\| -I eth0' "$T/net-calls" ||
        lw_fail "R77 $kind: a ping not bound to the session's device"
done

# --- R77: some replies with a nonzero exit (busybox with -w and -c) still count
lw_session v4
lw_reach_none
lw_reach 4 wwan0 8.8.8.8 partial
round
lw_expect_eq "$rc/$LW_P_OK4" "0/1" "R77: one reply of two counts"
lw_expect_eq "$LW_P_MS" 36.459 "R77: the round trip of a partial answer"

# --- R77c: every round reads the session again
lw_session v4
lw_reach_none
lw_reach 4 wwan0
lw_reach 4 464-wwan_6_4
lw_reach 6 wwan0
round
lw_expect_eq "$LW_P_DEV4/${LW_P_DEV6:-none}" "wwan0/none" "R77c: IPv4 session"
lw_session v6clat
round
lw_expect_eq "$LW_P_DEV4/$LW_P_DEV6" "464-wwan_6_4/wwan0" "R77c: the translation came"
lw_session dual
round
lw_expect_eq "$LW_P_DEV4/$LW_P_DEV6" "wwan0/wwan0" "R77c: the native IPv4 is back"
lw_session v4
round
lw_expect_eq "$LW_P_DEV4/${LW_P_DEV6:-none}" "wwan0/none" "R77c: IPv6 is gone"
# a session with the native IPv4 and the translation uses the native device
lw_session dual
cp "$T/ifstatus/wwan.json" "$T/ifstatus/wwan_6_4.json"
round
lw_expect_eq "$LW_P_DEV4/$LW_P_XLAT" "wwan0/0" "R76d: the native IPv4 wins over a translation"
rm -f "$T/ifstatus/wwan_6_4.json"

# --- each consumer keeps the ping it always had, for IPv4 and IPv6 alike (R14, R77): the recovery
# script's has no outer limit and counts any reply, lw-notify's has a 5 s limit and the exit status
lw_session dual
lw_reach 4 wwan0
lw_reach 6 wwan0
round
lw_expect_eq "$(grep '^ping ' "$T/net-calls")" "ping -4 -I wwan0 -c 2 -w 3 -q 8.8.8.8
ping -6 -I wwan0 -c 2 -w 3 -q $V6A" "R77: the recovery script's ping"
: >"$T/net-calls"
lw_probe_round notify
lw_expect_eq "$(grep '^ping ' "$T/net-calls")" "ping -4 -c 2 -w 3 -I wwan0 8.8.8.8
ping -6 -c 2 -w 3 -I wwan0 $V6A" "R77: lw-notify's ping"
lw_expect_eq "$LW_P_ONLINE/$LW_P_MS" "1/36.459" "R77: notify round trip, IPv4 before IPv6"
# a partial answer has exit status 1: lw-notify goes on to the next address, as before
lw_session v4
lw_reach_none
lw_reach 4 wwan0 8.8.8.8 partial
lw_reach 4 wwan0 1.1.1.1
lw_probe_round notify
lw_expect_eq "$LW_P_ONLINE" 1 "R77: notify, the second address answers"
lw_reach_none
lw_reach 4 wwan0 8.8.8.8 partial
lw_probe_round notify || :
lw_expect_eq "$LW_P_ONLINE" 0 "R77: notify keeps the exit status rule"

# --- R77c: a round ends when every ping hangs: lw-notify's limit of 5 s (here 1 s) per address
lw_session dual
touch "$T/net/hang"
LW_P_NOTIFY_LIMIT=1
t0=$(date +%s)
: >"$T/syslog"
lw_probe_round notify || rc=$?
t1=$(date +%s)
[ $((t1 - t0)) -le 8 ] || lw_fail "R77c: a round with hung pings took $((t1 - t0)) s"
[ $((t1 - t0)) -ge 3 ] || lw_fail "R77c: a round with hung pings took only $((t1 - t0)) s, not all four addresses"
lw_expect_eq "$LW_P_ONLINE/$LW_P_OK4/$LW_P_OK6" "0/0/0" "R77c: hung pings are no answer"
rm -f "$T/net/hang"
lw_reach_off

# --- R18c: the operator DNS of the session
dns_of() { lw_probe_dns >/dev/null || :; echo "$LW_P_DNS"; }
lw_session v4
lw_expect_eq "$(dns_of)" 192.0.2.53 "R18c v4: the lease's server"
lw_session dual
lw_expect_eq "$(dns_of)" 192.0.2.53 "R18c dual: the IPv4 lease comes first"
printf '{"up":true,"l3_device":"wwan0","dns-server":[]}\n' >"$T/ifstatus/wwan_4.json"
lw_expect_eq "$(dns_of)" 2001:db8:53::1 "R18c dual: the IPv6 setting when the lease has none"
lw_session v6
lw_expect_eq "$(dns_of)" 2001:db8:53::1 "R18c v6: the IPv6 setting of wwan"
lw_session v6clat
lw_expect_eq "$(dns_of)" 2001:db8:53::1 "R18c v6clat: the translation has none of its own"
lw_session v6child
lw_expect_eq "$(dns_of)" 2001:db8:53::1 "R18c v6child: the IPv6 setting of wwan_6"
# no server: no answer from this source
lw_session v4
printf '{"up":true,"dns-server":[]}\n' >"$T/ifstatus/wwan_4.json"
lw_expect_eq "$(dns_of)" "" "R18c: a lease without a server"
if lw_probe_dns; then lw_fail "R18c: a lease without a server has an operator DNS"; fi
# a DNS server that wwan carries without an IPv6 session (a tunnel's, say) is not the operator's
printf '{"up":true,"l3_device":"wwan0","dns-server":["198.51.100.7"]}\n' >"$T/ifstatus/wwan.json"
lw_expect_eq "$(dns_of)" "" "R18c: no IPv6 in the session, no IPv6 settings to read"
rm -f "$T"/ifstatus/*.json
lw_expect_eq "$(dns_of)" "" "R18c: no data at all"

# A delegated prefix can be the only global IPv6 on a live cellular WAN.
for iface in wwan wwan_6; do
    lw_session v6child
    printf '{"up":false}\n' >"$T/ifstatus/wwan_6.json"
    printf '{"up":true,"data":{"cid_6":"18","pdh_6":"42"}}\n' >"$T/ifstatus/wwan.json"
    printf '%s\n' '{"up":true,"l3_device":"wwan0","ipv6-prefix":[{"address":"fd00::"},{"address":"2001:db8::"}],"data":{"cid_6":"18","pdh_6":"42"}}' \
        >"$T/ifstatus/$iface.json"
    lw_probe_session
    lw_expect_eq "$LW_P_DEV6" wwan0 "IPv6 device of prefix-only $iface"
done

# --- R18c: the server counts only when its route leaves on the cellular device of its family
LW_LOG_LEVEL=debug
dns_path() {
    : >"$T/syslog.prio"
    lw_probe_dns || lw_fail "R18c: no operator DNS"
    rc=0
    lw_probe_dns_path || rc=$?
}
for kind in legacy v4 dual v6 v6clat v6child; do
    lw_session "$kind"
    lw_route_off
    dns_path
    lw_expect_eq "$rc" 0 "R18c $kind: the route leaves on wwan0"
    lw_expect_eq "$(cat "$T/syslog.prio")" "" "R18c $kind: nothing said when it does"
    lw_route_none
    dns_path
    lw_expect_eq "$rc" 1 "R18c $kind: no route, no evidence"
    for dev in wg0 tailscale0 br-lan eth1 464-wwan_6_4; do
        lw_route_none
        lw_route "$LW_P_DNS" "$dev"
        dns_path
        lw_expect_eq "$rc" 1 "R18c $kind: a competing route over $dev is no evidence"
    done
    lw_expect_grep "$T/syslog.prio" "daemon.debug lw-probe: operator DNS $LW_P_DNS: route leaves on '464-wwan_6_4', the session's device is '"
    lw_route_none
    lw_route "$LW_P_DNS" wwan0
    dns_path
    lw_expect_eq "$rc" 0 "R18c $kind: a route of that server over wwan0"
done
# R18c: a failed route lookup cannot prove egress even if it wrote a route.
lw_session v4
lw_route_off
touch "$T/net/route-error"
dns_path
lw_expect_eq "$rc" 1 "R18c: a failed route lookup is no evidence"
rm -f "$T/net/route-error"
# IPv6 server: the device of IPv6, not of IPv4 (the translation's device is not the operator DNS' path)
lw_session v6clat
lw_route_none
lw_route 2001:db8:53::1 464-wwan_6_4
dns_path
lw_expect_eq "$rc" 1 "R18c: an IPv6 server routed over the translation device is no evidence"
# the server of a session whose IPv6 has no device yet
lw_session v6child
printf '{"up":false}\n' >"$T/ifstatus/wwan_6.json"
printf '{"up":true,"l3_device":"wwan0","dns-server":["2001:db8:53::1"],"data":{"cid_6":"18","pdh_6":"3203210530"}}\n' >"$T/ifstatus/wwan.json"
lw_route_off
dns_path
lw_expect_eq "$rc" 1 "R18c: no device, no evidence"
lw_route_off
# Static native IPv4 publishes its DNS on the parent.
lw_session v4
rm -f "$T/ifstatus/wwan_4.json"
printf '%s\n' '{"up":true,"ipv4-address":[{"address":"192.0.2.2"}],"dns-server":["2001:db8::53","192.0.2.53"],"data":{"cid_4":"17","pdh_4":"42"}}' \
    >"$T/ifstatus/wwan.json"
lw_expect_eq "$(dns_of)" 192.0.2.53 "R18c: static native IPv4 DNS"

echo ok
