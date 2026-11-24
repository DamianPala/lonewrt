# R14g, R49d, D204: the line that the real writer (lw_probe_publish_v6 of probe.sh, run as watchcat's
# hook runs it) puts in /tmp/lw-family/ipv6 is what the watcher reads: a check of this session after the
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
lw_expect_eq "$(cat /tmp/lw-family/ipv6)" "17/3203210528 400 1000 none" "the line of the writer"
lw-linkwatch once
lw_expect_eq "$(ifups)" 1 "ifup wwan events after the writer's none"

# the same check taken before the loss was seen does not count: the writer's second is 990 here
failing
lw_uptime_set 990
check
lw_expect_eq "$(cat /tmp/lw-family/ipv6)" "17/3203210528 400 990 none" "the line of the writer before the loss"
lw_uptime_set 1000
lw-linkwatch once
lw_expect_eq "$(ifups)" 0 "ifup wwan events after a none from before the loss"

# an answer
failing
lw_reach 6 wwan0
check
lw_expect_eq "$(cat /tmp/lw-family/ipv6)" "17/3203210528 400 1000 answer" "the line of the writer, answered"
lw-linkwatch once
lw_expect_eq "$(ifups)" 0 "ifup wwan events after the writer's answer"

# no IPv6 device: nodev, which the watcher does not take for silence
failing
sed -i 's/"ipv6-address":\[[^]]*\],//' "$T/ifstatus/wwan.json"
check
lw_expect_eq "$(cat /tmp/lw-family/ipv6)" "17/3203210528 400 1000 nodev" "the line of the writer without an IPv6 device"
lw-linkwatch once
lw_expect_eq "$(ifups)" 0 "ifup wwan events after the writer's nodev"
