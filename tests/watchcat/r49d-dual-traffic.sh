# R14g, R49d, R77d, D196, D200, D204: the IPv6 result that watchcat's check hands to the session
# watcher, in a dual-stack session, has three words besides `nodev`:
#   answer   an IPv6 probe answered, or the traffic measure (R77d) shows IPv6 traffic
#   none     no IPv6 probe answered and the measure is quiet (a valid sample, no traffic)
#   unknown  no IPv6 probe answered and the measure is unknown (no baseline, no counters, another
#            session): the watcher keeps IPv6 for anything but an exact `none`
# With IPv6 traffic the silence timer of watchcat is fed too, so a lost IPv4 call does not restart a
# parent whose IPv6 still carries TCP; with both families dead the repair is as before.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/watchcat/helpers.inc
. /fw/tests/watchcat/helpers.inc

F=/var/run/lw-family/ipv6

steps() {
    printf '#!/bin/sh\n/fw/tests/stubs/snmp6-add wwan0 %s %s %s %s\n' "$1" "$2" "$3" "$4" >"$T/on-sleep"
    chmod +x "$T/on-sleep"
}
result() { sed 's/.* //' "$F"; }
# dual STEPS HORIZON: a dual-stack session whose probes get no answer, the counters of wwan0 rising by
# STEPS (received, transmitted, ICMPv6 in, ICMPv6 out) at every nap
dual() {
    wc_setup
    lw_session dual
    snmp6-add wwan0 0 0 0 0
    # shellcheck disable=SC2086
    steps $1
    wc_clock 1000
    wc_run hook "$2"
}

# the IPv4 call is lost for good (silent probes), IPv6 carries TCP through a whole period of the
# timer and more: answer, and wwan is not restarted
dual '60 60 0 0' 1700
lw_expect_eq "$(result)" answer "result of a silent IPv6 with traffic"
lw_expect_eq "$(wc_ifups)" "" "restarts of a session whose IPv6 carries traffic"

# then both families are dead: no traffic, the timer runs out and wwan is restarted as before
steps 0 0 0 0
wc_run hook 2100
[ -n "$(wc_ifups)" ] || lw_fail "no restart when IPv6 traffic stopped and both families are silent"

# silence of the probes and the measure quiet: none
dual '0 0 0 0' 1400
lw_expect_eq "$(result)" none "result of a silent IPv6 without traffic"

# ICMPv6 alone (advertisements, neighbour discovery, the probes) is quiet, not traffic
dual '60 60 60 60' 1400
lw_expect_eq "$(result)" none "result with ICMPv6 only"

# one way only, and a trickle: quiet
for st in '60 0 0 0' '0 60 0 0' '3 3 0 0'; do
    dual "$st" 1400
    lw_expect_eq "$(result)" none "result with traffic '$st'"
done

# the first check of a worker has no baseline: unknown, not none
dual '60 60 0 0' 1100
lw_expect_eq "$(result)" unknown "result of the first check (no baseline)"

# no counters: unknown
wc_setup
lw_session dual
wc_clock 1000
wc_run hook 1400
lw_expect_eq "$(result)" unknown "result without counters"

# the IPv4 answers: its probes say nothing about IPv6; the IPv6 result is the IPv6 one
wc_setup
lw_session dual
lw_reach 4 wwan0
snmp6-add wwan0 0 0 0 0
steps 0 0 0 0
wc_clock 1000
wc_run hook 1400
lw_expect_eq "$(result)" none "result with IPv4 answering and IPv6 quiet"
wc_setup
lw_session dual
lw_reach 4 wwan0
snmp6-add wwan0 0 0 0 0
steps 60 60 0 0
wc_clock 1000
wc_run hook 1400
lw_expect_eq "$(result)" answer "result with IPv4 answering and IPv6 traffic"

# IPv6 answers: answer, with or without traffic
wc_setup
lw_session dual
lw_reach 6 wwan0
steps 0 0 0 0
wc_clock 1000
wc_run hook 1400
lw_expect_eq "$(result)" answer "result of an answering IPv6"

# the line keeps its fields
dual '60 60 0 0' 1400
lw_expect_eq "$(cut -d' ' -f1 "$F")" 17/3203210528 "session field"
