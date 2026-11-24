# R14g, R49d, D204: the line that the real writer (lw_probe_publish_v6 of probe.sh, run as watchcat's
# hook runs it) puts in /var/run/lw-family/ipv6 is what the watcher reads: a check of this session after the
# loss with no IPv6 answer lets it run `ifup wwan`; an answer, or an IPv6 call with no device (nodev),
# keeps IPv6. The fixtures of r49d-sibling-escalation.sh write the line by hand; this one does not.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc

# failing: a dual-stack session that came up at second 400, with an IPv6 address on wwan, whose IPv4
# start never works; the clock is at 1000 s when the loss is seen
failing() {
    lk_setup
    LK_IFBIRTH=400
    lk_netifd up dual
    unset LK_IFBIRTH
    sed -i 's/^{/{"ipv6-address":[{"address":"2001:db8:1::2","mask":128}],/' "$T/ifstatus/wwan.json"
    echo up >"$T/uqmi/session-18"
    lk_lost
    echo '"Call failed"' >"$T/uqmi/q-start"
    lw_reach_none
}
# the check of watchcat at the second of the loss
check() {
    # shellcheck source=src/files/usr/lib/lw/common.sh
    . /usr/lib/lw/common.sh
    # shellcheck source=src/files/usr/lib/lw/probe.sh
    . /usr/lib/lw/probe.sh
    lw_probe_round watchcat || :
    lw_probe_publish_v6
}
ifups() { grep -c '^ifup wwan$' "$EVENTS" || true; }

# silent IPv6: the writer's line is `none` of this session and birth, and the watcher restarts wwan
failing
check
lw_expect_eq "$(cat /var/run/lw-family/ipv6)" "17/3203210528 400 1000 none" "the line of the writer"
lw-linkwatch once
lw_expect_eq "$(ifups)" 1 "ifup wwan events after the writer's none"

# the same check taken before the loss was seen does not count: the writer's second is 990 here
failing
lw_uptime_set 990
check
lw_expect_eq "$(cat /var/run/lw-family/ipv6)" "17/3203210528 400 990 none" "the line of the writer before the loss"
lw_uptime_set 1000
lw-linkwatch once
lw_expect_eq "$(ifups)" 0 "ifup wwan events after a none from before the loss"

# an answer
failing
lw_reach 6 wwan0
check
lw_expect_eq "$(cat /var/run/lw-family/ipv6)" "17/3203210528 400 1000 answer" "the line of the writer, answered"
lw-linkwatch once
lw_expect_eq "$(ifups)" 0 "ifup wwan events after the writer's answer"

# no IPv6 device: nodev, which the watcher does not take for silence
failing
sed -i 's/"ipv6-address":\[[^]]*\],//' "$T/ifstatus/wwan.json"
check
lw_expect_eq "$(cat /var/run/lw-family/ipv6)" "17/3203210528 400 1000 nodev" "the line of the writer without an IPv6 device"
lw-linkwatch once
lw_expect_eq "$(ifups)" 0 "ifup wwan events after the writer's nodev"

# R14g, R49d, R77d, D198, D200: the line that watchcat's own check writes (lw_wc_check, which takes
# the traffic measure before the writer) in a dual-stack session whose IPv4 call is lost and whose IPv6
# probes get no answer. IPv6 traffic since the previous check reports `answer`; a valid sample with no
# traffic reports `none`; no valid sample (the first check, no counters, another session) reports
# `unknown`. The watcher restarts wwan only on an exact `none`; the other two keep IPv6.
# shellcheck source=src/files/usr/lib/lw/watchcat-family.sh
. /usr/lib/lw/watchcat-family.sh
wc_check() {
    # shellcheck disable=SC2034  # the worker's variables, read by watchcat-family.sh
    time_now=$(lw_uptime)
    time_lastcheck_withinternet=$time_now
    iface=wwan
    ping_size=56
    failure_period=120
    # shellcheck disable=SC2034  # the same
    ping_frequency_interval=60
    lw_wc_check
}
# two checks, the second after the counters rose by RECEIVED TRANSMITTED ICMP_IN ICMP_OUT
two_checks() {
    _lw_wc_base=''
    snmp6-add wwan0 0 0 0 0
    wc_check
    snmp6-add wwan0 "$@"
    wc_check
}
line() { cat /var/run/lw-family/ipv6; }

failing
two_checks 60 60 0 0
lw_expect_eq "$(line)" "17/3203210528 400 1000 answer" "the line of the check after traffic"
lw-linkwatch once
lw_expect_eq "$(ifups)" 0 "ifup wwan events when IPv6 carried traffic"

failing
two_checks 0 0 0 0
lw_expect_eq "$(line)" "17/3203210528 400 1000 none" "the line of the check without traffic"
lw-linkwatch once
lw_expect_eq "$(ifups)" 1 "ifup wwan events when IPv6 was quiet"

# ICMPv6 alone is quiet
failing
two_checks 60 60 60 60
lw_expect_eq "$(line)" "17/3203210528 400 1000 none" "the line of the check with ICMPv6 only"

# the first check has no baseline: unknown, and the watcher keeps IPv6 (D196, D200)
failing
_lw_wc_base=''
snmp6-add wwan0 0 0 0 0
wc_check
lw_expect_eq "$(line)" "17/3203210528 400 1000 unknown" "the line of the first check"
lw-linkwatch once
lw_expect_eq "$(ifups)" 0 "ifup wwan events after an unknown IPv6 result"
lw_expect_eq "$(lk_info)" 1 "watcher syslog lines after an unknown IPv6 result"
lk_lines | grep -qE " lw-linkwatch: data session lost, not restored in place after 20 s, IPv6 kept, no ifup\$" ||
    lw_fail "info line: $(lk_lines)"

# no counters: unknown too
failing
rm -rf "$LW_TRAFFIC_SNMP6"
_lw_wc_base=''
wc_check
wc_check
lw_expect_eq "$(line)" "17/3203210528 400 1000 unknown" "the line of a check without counters"
lw-linkwatch once
lw_expect_eq "$(ifups)" 0 "ifup wwan events without counters"

# a family directory that is a link: the writer writes nothing through it, and the watcher has no
# silence to act on (a result was in the target before: it is not believed there either)
failing
mkdir -p /tmp/elsewhere
echo "17/3203210528 400 1005 none" >/tmp/elsewhere/ipv6
ln -s /tmp/elsewhere /var/run/lw-family
check
lw_expect_eq "$(cat /tmp/elsewhere/ipv6)" "17/3203210528 400 1005 none" "the file behind the link is not rewritten"
lw_expect_eq "$(ls -A /tmp/elsewhere)" ipv6 "files behind the link"
lw-linkwatch once
lw_expect_eq "$(ifups)" 0 "ifup wwan events with the family directory a link"
