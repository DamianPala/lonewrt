# The recovery ladder on every kind of link (R77, R18c, D173): IPv4 only, dual stack, IPv6 only, IPv6
# with the translation, IPv6 only through the child wwan_6. A link that answers on one family is
# online and never starts a failure; a dead link takes the ladder and its class as always; the class
# account reads the operator DNS of the session (IPv4 lease first, else IPv6 settings) and needs one;
# an answer over another interface is none; and an IPv4-only link sees no IPv6 ping (R77a).
# shellcheck source=tests/ladder/ladder.inc
. /fw/tests/ladder/ladder.inc

# up KIND [FAMILY...]: the session of that kind, and which of its paths answer: "4" the native
# or translated IPv4, "6" the IPv6; no argument = all it has
up() {
    _k=$1
    shift
    lw_session "$_k"
    lw_reach_none
    [ $# -gt 0 ] || case $_k in
        v4) set -- 4 ;;
        dual | v6clat) set -- 4 6 ;;
        *) set -- 6 ;;
    esac
    for _f in "$@"; do
        case $_f$_k in
            4v6clat) lw_reach 4 464-wwan_6_4 ;;
            4*) lw_reach 4 wwan0 ;;
            6*) lw_reach 6 wwan0 ;;
        esac
    done
}

# fresh: a new boot well past the grace, no failure, nothing sent, operator DNS silent, no ping log
fresh() {
    boot_sim 1000
    rm -f "$STATE" "$T/at"/*
    : >/root/openwrt.log
    : >"$T/net-calls"
    : >"$T/events"
    : >"$T/reboot-runs"
    : >"$T/syslog"
    rm -rf /tmp/lw-probe
    run=0
    lw_net down down
    lw_dns down down
    echo 0 >"$T/net/txbump"
}

# healthy KIND [FAMILY...]: LTE-only mode, `runs` cron runs, no failure at all
healthy() {
    _k=$1
    fresh
    up "$@"
    runs 12
    [ ! -e "$STATE" ] || lw_fail "R77 $_k ($*): a failure was counted: $(cat "$STATE")"
    lw_expect_eq "$(reboot_runs)" "" "R77 $_k ($*): reboots"
    lw_expect_eq "$(mode_now)" lte "R77 $_k ($*): mode"
    lw_expect_no_grep "$T/syslog" "wwan-recover: offline"
    lw_expect_no_grep "$T/syslog" "EDGE"
    lw_expect_no_grep "$T/events" "^ifup"
}

# --- D173: a link with one working path is online, whichever it is
for kind in v4 dual v6 v6clat v6child; do
    healthy "$kind"
done
healthy dual 4
healthy dual 6
healthy v6clat 4
healthy v6clat 6

# --- R77: a dead link takes the ladder: the first reboot at cycle 6, class hang, on every kind
for kind in v4 dual v6 v6clat v6child; do
    fresh
    up "$kind"
    lw_reach_none
    runs 6
    lw_expect_eq "$(reboot_runs)" 6 "R77 $kind: the first reboot at cycle 6"
    lw_expect_eq "$(state_get class)" hang "R77 $kind: class"
    lw_expect_eq "$(state_get cycles)" 6 "R77 $kind: cycles"
done

# --- R77: an answer over the tunnel, Tailscale, the LAN or an unbound ping is not a cellular answer
for kind in v4 dual v6 v6clat; do
    fresh
    up "$kind"
    lw_reach_none
    for dev in - wg0 tailscale0 br-lan; do
        lw_reach 4 "$dev"
        lw_reach 6 "$dev"
    done
    runs 6
    lw_expect_eq "$(reboot_runs)" 6 "R77 $kind: an answer through another interface counts as none"
    lw_expect_eq "$(state_get class)" hang "R77 $kind: class with another interface answering"
done

# --- R18c: package used up (pings fail, the operator DNS answers, traffic goes out): class account
# on every kind, the query goes to the server of the session
server_of() {
    case $1 in v4 | dual) echo 192.0.2.53 ;; *) echo 2001:db8:53::1 ;; esac
}
for kind in v4 dual v6 v6clat v6child; do
    fresh
    up "$kind"
    lw_reach_none
    lw_dns up down
    echo 4 >"$T/net/txbump"
    runs 1
    lw_expect_eq "$(state_get class)" account "R18c $kind: class"
    lw_expect_grep "$T/net-calls" "^nslookup openwrt.org $(server_of "$kind")\$"
    # the ladder of an account stops at 2 reboots and never takes EDGE (R19, R25)
    runs 40
    lw_expect_eq "$(reboot_runs)" "6 18" "R18c $kind: reboots of class account"
    lw_expect_eq "$(wr_at 'EDGE')" "" "R18c $kind: no EDGE for class account"
done

# R18c: a reachable server whose route leaves on another interface (a tunnel, the LAN, another WAN)
# is no evidence: the class does not latch account, and the server is not even asked
for kind in v4 dual v6 v6clat v6child; do
    for dev in wg0 br-lan eth1; do
        fresh
        up "$kind"
        lw_reach_none
        lw_dns up down
        echo 4 >"$T/net/txbump"
        lw_route "$(server_of "$kind")" "$dev"
        runs 1
        lw_expect_eq "$(state_get class)" unknown "R18c $kind: server routed over $dev, no class account"
        lw_expect_no_grep "$T/net-calls" "^nslookup"
        lw_route_off
    done
done
# the same server over wwan0, as an IPv4-only session has it, latches account as before
fresh
up v4
lw_reach_none
lw_dns up down
echo 4 >"$T/net/txbump"
lw_route 192.0.2.53 wwan0
runs 1
lw_expect_eq "$(state_get class)" account "R18c v4: the route over wwan0 is evidence"
lw_route_off

# the lease's server is read before the IPv6 settings, also on dual stack with both
fresh
up dual
lw_reach_none
lw_dns up down
echo 4 >"$T/net/txbump"
runs 1
lw_expect_no_grep "$T/net-calls" "nslookup openwrt.org 2001:db8:53::1"

# a session without an operator DNS cannot be class account
for kind in v4 v6 v6clat; do
    fresh
    up "$kind"
    lw_reach_none
    lw_dns up down
    echo 4 >"$T/net/txbump"
    if [ "$kind" = v4 ]; then
        printf '{"up":true,"l3_device":"wwan0","dns-server":[]}\n' >"$T/ifstatus/wwan_4.json"
    else
        printf '{"up":true,"l3_device":"wwan0","ipv6-address":[{"address":"2001:db8:1::2","mask":128}]}\n' \
            >"$T/ifstatus/wwan.json"
    fi
    runs 1
    lw_expect_eq "$(state_get class)" unknown "R18c $kind: no operator DNS, no class account"
    lw_expect_no_grep "$T/net-calls" "^nslookup"
done

# --- R77a: an IPv4-only link sees no IPv6 address in any cycle, healthy or not, with or without the
# netifd data of wwan; the debugging of an operator without IPv6 is not made harder by timeouts
for data in seed legacy v4; do
    fresh
    if [ "$data" = seed ]; then
        rm -f "$T"/ifstatus/*.json
        printf '{"up":true,"dns-server":["192.0.2.53"]}\n' >"$T/ifstatus/wwan_4.json"
    else
        lw_session "$data"
    fi
    lw_reach_none
    lw_reach 4 wwan0
    runs 3
    lw_reach_none
    lw_dns up down
    echo 4 >"$T/net/txbump"
    runs 8
    ! grep -q -- ' -6 \|::' "$T/net-calls" || lw_fail "R77a $data: an IPv6 ping: $(grep -- ' -6 \|::' "$T/net-calls")"
    lw_expect_no_grep "$T/syslog" "lw-probe"
    lw_expect_no_grep "$T/syslog" "IPv6"
done
check_format
echo ok
