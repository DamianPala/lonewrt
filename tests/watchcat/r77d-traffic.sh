# R77d, D198: in a session without native IPv4, before watchcat restarts wwan for silence, IPv6
# traffic of the session's own device that answered a connection from inside since the previous check,
# other than the probes, counts as online for that check. The measure is the packet counters of the
# device: at least 4 packets received and 4 sent beyond the probes between two checks. A session with
# native IPv4 is judged by the probes alone.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/watchcat/helpers.inc
. /fw/tests/watchcat/helpers.inc

STATS=/tmp/netdev
export LW_WC_STATS=$STATS

# counters RX TX: the device's counters, which the stand-in `sleep` then raises by RX_STEP and TX_STEP
# at every nap (once per check)
counters() {
    mkdir -p "$STATS/wwan0/statistics"
    echo "$1" >"$STATS/wwan0/statistics/rx_packets"
    echo "$2" >"$STATS/wwan0/statistics/tx_packets"
}
steps() {
    cat >"$T/on-sleep" <<EOS
#!/bin/sh
d=$STATS/wwan0/statistics
echo \$((\$(cat \$d/rx_packets) + $1)) >\$d/rx_packets
echo \$((\$(cat \$d/tx_packets) + $2)) >\$d/tx_packets
EOS
    chmod +x "$T/on-sleep"
}

# an IPv6-only session whose probes get no answer while a connection carries traffic both ways: no
# restart, however long
wc_setup
lw_session v6
counters 1000 1000
steps 60 60
wc_clock 1000
wc_run hook 1700
lw_expect_eq "$(wc_ifups)" "" "restarts of an IPv6-only session with answered traffic"

# the same with the IPv4 over the translation (it is IPv6 on the device)
wc_setup
lw_session v6clat
counters 1000 1000
steps 60 60
wc_clock 1000
wc_run hook 1700
lw_expect_eq "$(wc_ifups)" "" "restarts of a translated session with answered traffic"

# no traffic: the silence is real, wwan is restarted when the timer runs out
wc_setup
lw_session v6
counters 1000 1000
steps 0 0
wc_clock 1000
wc_run hook 1400
[ -n "$(wc_ifups)" ] || lw_fail "no restart of a silent IPv6-only session without traffic"

# only our own probes on the wire: sent, and nothing received
wc_setup
lw_session v6
counters 1000 1000
steps 0 2
wc_clock 1000
wc_run hook 1400
[ -n "$(wc_ifups)" ] || lw_fail "no restart when only probes went out"

# packets in, none out (unsolicited traffic) and out, none in (a connection that is not answered)
for st in '60 0' '0 60'; do
    wc_setup
    lw_session v6
    counters 1000 1000
    # shellcheck disable=SC2086
    steps $st
    wc_clock 1000
    wc_run hook 1400
    [ -n "$(wc_ifups)" ] || lw_fail "no restart with traffic one way only ($st)"
done

# a trickle below the threshold (router advertisements, neighbour discovery)
wc_setup
lw_session v6
counters 1000 1000
steps 3 3
wc_clock 1000
wc_run hook 1400
[ -n "$(wc_ifups)" ] || lw_fail "no restart with a trickle of packets"

# a session with native IPv4: the probes alone decide, traffic on the device is not looked at
wc_setup
lw_session dual
counters 1000 1000
steps 60 60
wc_clock 1000
wc_run hook 1500
[ -n "$(wc_ifups)" ] || lw_fail "no restart of a session with native IPv4 and silent probes, traffic or not"

# counters that cannot be read: the probes alone decide
wc_setup
lw_session v6
steps 60 60
rm -rf "$STATS"
wc_clock 1000
wc_run hook 1400
[ -n "$(wc_ifups)" ] || lw_fail "no restart with unreadable counters"
