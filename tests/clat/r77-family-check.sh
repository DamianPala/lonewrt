# R76, R76a, R77, R77a, R77c, D185: in an IPv6-only session the family check counts an IPv4 answer that
# came through the translation device 464-wwan_6_4 that lw-clat-check set up, and no other: a reply to
# a ping bound to wwan0 is none, an IPv4 address is not pinged while the translation is not up (not
# made, being made, failed or down), a translation that is not up never makes the session look like
# one that lost its IPv4, and the check follows the translation when it comes and goes without a
# restart of anything.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/clat/helpers.inc
. /fw/tests/clat/helpers.inc

round() {
    : >"$T/net-calls"
    rc=0
    lw_probe_round "${1:-recover}" || rc=$?
}
calls() { grep '^ping ' "$T/net-calls" | sed 's/ -c 2 -w 3 -q//'; }

cl_setup
# shellcheck source=src/files/usr/lib/lw/common.sh
. /usr/lib/lw/common.sh
# shellcheck source=src/files/usr/lib/lw/probe.sh
. /usr/lib/lw/probe.sh

# no translation (DNS64 does not answer): the session has IPv6 and no IPv4 service, so no IPv4 ping
cl_dns_off
cl_tick
lw_reach 6 wwan0
round
lw_expect_eq "$rc" 0 "no translation: online over IPv6"
lw_expect_eq "$LW_P_HAS4/$LW_P_HAS6/$LW_P_XLAT/$LW_P_V6ONLY" "0/1/0/1" "no translation: families"
lw_expect_eq "$(calls)" "ping -6 -I wwan0 2001:4860:4860::8888" "R77a: no ping to an IPv4 address"

# a translation that failed or is being made is not IPv4 service either: nothing is pinged on it, and
# the families of the session are those of IPv6 alone
for st in '{"up":false,"pending":false}' '{"up":false,"pending":true}' '{"up":false}'; do
    printf '%s\n' "$st" >"$T/ifstatus/wwan_6_4.json"
    round
    lw_expect_eq "$rc" 0 "translation $st: online over IPv6"
    lw_expect_eq "$LW_P_HAS4/$LW_P_HAS6/$LW_P_XLAT/${LW_P_DEV4:-none}" "0/1/0/none" "translation $st: families"
    lw_expect_eq "$(calls | grep -c ' -4 ')" 0 "translation $st: no IPv4 ping"
done
# the IPv6 answer is gone too: offline, and the IPv4 family never existed to be lost
lw_reach_none
printf '{"up":false}\n' >"$T/ifstatus/wwan_6_4.json"
round
lw_expect_eq "$rc/$LW_P_OK4/$LW_P_OK6" "1//0" "translation failed, IPv6 silent: offline, IPv4 not counted"
rm -f "$T/ifstatus/wwan_6_4.json"

# the translation comes up: the IPv4 family appears at the next check, on its own device
cl_dns "$DNS_ADDR" "$WKP_ANSWER"
cl_tick
lw_reach_none
lw_reach 6 wwan0
lw_reach 4 464-wwan_6_4 8.8.8.8
round watchcat
lw_expect_eq "$rc" 0 "translation: online"
lw_expect_eq "$LW_P_HAS4/$LW_P_HAS6/$LW_P_XLAT/$LW_P_DEV4" "1/1/1/464-wwan_6_4" "translation: families and device"
lw_expect_eq "$LW_P_OK4/$LW_P_OK6" "1/1" "translation: both families answer"
lw_expect_eq "$(calls)" "ping -4 -I 464-wwan_6_4 -s 56 -c 1 8.8.8.8
ping -6 -I wwan0 -s 56 -c 1 2001:4860:4860::8888" "R77: the IPv4 ping is bound to the translation device"

# IPv4 answers only through the translation: the family check is online on that alone
lw_reach_none
lw_reach 4 464-wwan_6_4
round recover
lw_expect_eq "$rc/$LW_P_OK4/$LW_P_OK6" "0/1/0" "R76: online through IPv4 over the translation alone"

# a reply that comes over wwan0 for an IPv4 address is no cellular answer
lw_reach_none
lw_reach 4 wwan0
round recover
lw_expect_eq "$rc/$LW_P_OK4" "1/0" "an IPv4 reply on wwan0 is none"

# the translation stops and is taken out: the next check has no IPv4 family any more
lw_session v6child
round recover
lw_expect_eq "$LW_P_HAS4" 0 "translation gone: no IPv4 family at the next check"
lw_expect_eq "$(calls | grep -c ' -4 ')" 0 "translation gone: no IPv4 ping"

# a session that had native IPv4 is not an IPv6-only one, whatever the translation interface says
lw_session dual
printf '{"up":true,"l3_device":"464-wwan_6_4"}\n' >"$T/ifstatus/wwan_6_4.json"
round recover
lw_expect_eq "$LW_P_V6ONLY/$LW_P_XLAT" "0/0" "dual stack: not the session of a translation"
echo ok
