# R77d, D198, D200: in a session with an IPv6 call (IPv6 alone, with or without the translation, and
# dual stack) IPv6 traffic that answered a connection since the previous check counts as online for
# watchcat's silence timer, so a working IPv6 is never restarted for silent probes. The measure is the
# per-device IPv6 counters of the kernel (/proc/net/dev_snmp6/<dev>): at least 4 packets in and 4 out
# per window, with the ICMPv6 messages of the router itself (advertisements, neighbour discovery, the
# probes) taken off; IPv4 never counts. Quiet or unknown (no baseline, no counters, another session)
# leaves the probes to decide. A session without IPv6 reads no counters.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/watchcat/helpers.inc
. /fw/tests/watchcat/helpers.inc

# steps RECEIVED TRANSMITTED ICMP_IN ICMP_OUT: the counters of wwan0 rise by that at every nap (once
# per check), as tests/stubs/snmp6-add does it
steps() {
    printf '#!/bin/sh\n/fw/tests/stubs/snmp6-add wwan0 %s %s %s %s\n' "$1" "$2" "$3" "$4" >"$T/on-sleep"
    chmod +x "$T/on-sleep"
}
# silent KIND STEPS HORIZON: a session whose probes get no answer, until the clock reaches HORIZON
silent() {
    wc_setup
    lw_session "$1"
    snmp6-add wwan0 0 0 0 0
    # shellcheck disable=SC2086
    steps $2
    wc_clock 1000
    wc_run hook "$3"
}
restarts() { [ -n "$(wc_ifups)" ] || lw_fail "no restart: $1"; }
holds() { lw_expect_eq "$(wc_ifups)" "" "restarts: $1"; }

# traffic both ways, no probe answered: no restart, however long (IPv6 alone, translated, dual stack)
for kind in v6 v6clat v6child dual; do
    silent "$kind" '60 60 0 0' 1700
    holds "$kind with answered IPv6 traffic"
done

# the traffic stops: the silence is real and the timer restarts wwan as always
for kind in v6 dual; do
    silent "$kind" '0 0 0 0' 1400
    restarts "$kind without traffic"
done

# ICMPv6 alone is not traffic: advertisements, neighbour discovery and the probes themselves are all
# ICMPv6 (the same 60 packets both ways, all of them counted again as ICMPv6 messages)
for kind in v6 dual; do
    silent "$kind" '60 60 60 60' 1400
    restarts "$kind with ICMPv6 only"
done

# one way only (a stream that is not answered), and a trickle below the minimum
for kind in v6 dual; do
    for st in '60 0 0 0' '0 60 0 0' '3 3 0 0'; do
        silent "$kind" "$st" 1400
        restarts "$kind with '$st'"
    done
done

# a session without IPv6 reads no counters: the probes alone decide, whatever the files say
silent v4 '60 60 0 0' 1400
restarts "an IPv4-only session"

# counters that cannot be read: unknown, the probes alone
wc_setup
lw_session v6
wc_clock 1000
wc_run hook 1400
restarts "no counters"

# one mutation-sized check of the window: the minimum is 4 in and 4 out per check
silent v6 '4 4 0 0' 1700
holds "v6 with exactly the minimum"
silent v6 '3 4 0 0' 1400
restarts "v6 one packet under the minimum"
