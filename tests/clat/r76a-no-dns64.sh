# R76a, R76c, D186: an IPv6-only session whose operator DNS64 gives no usable answer for
# ipv4only.arpa has IPv6 without IPv4 service: no interface is added, one syslog line per session says
# so, nothing restarts wwan (no ifup, no ifdown). The next look is the next event of the IPv6 child or
# the next run of wwan-recover; once DNS64 answers, the translation comes up with no restart of wwan.
# An answer is unusable unless it is an address of the shape a /96 prefix gives for 192.0.0.170 or
# 192.0.0.171.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/clat/helpers.inc
. /fw/tests/clat/helpers.inc

# no answer at all, an answer with no address, a server that is not there
for what in down none ''; do
    cl_setup
    cl_dns_off
    [ -z "$what" ] || cl_dns "$DNS_ADDR" "$what"
    for i in 1 2 3; do
        cl_tick
        lw_expect_eq "$CL_RC" 0 "no answer ($what) look $i: exit status"
    done
    lw_expect_eq "$(cl_adds)" 0 "no answer ($what): interfaces added"
    lw_expect_eq "$(cl_live)" 0 "no answer ($what): helpers"
    lw_expect_eq "$(cl_clat_lines)" 1 "no answer ($what): one line in three looks ($(cat "$LOG"))"
    grep -q "no IPv4 for the router and the LAN yet: the operator's DNS64 gives no address for ipv4only.arpa; IPv6 works" "$LOG" ||
        lw_fail "no answer ($what): line: $(cat "$LOG")"
    lw_expect_eq "$(cat "$T/events")" "" "no answer ($what): ifup or ifdown"
    cl_clean_state "no answer ($what)"
    # a new session is a new line, the same session is not
    printf '{"up":true,"l3_device":"wwan0","data":{"cid_6":"31","pdh_6":"5550001"}}\n' >"$T/ifstatus/wwan.json"
    cl_tick
    cl_tick
    lw_expect_eq "$(cl_clat_lines)" 2 "no answer ($what): a new session says it once more"
done

# the hotplug's look asks again while the session settles: 3 questions, 2 s apart, one line
cl_setup
cl_dns_off
cl_new
lw_expect_eq "$(wc -l <"$C/dns-queries")" 3 "new: three questions"
lw_expect_eq "$(grep -c '^sleep 2$' "$T/sleeps")" 2 "new: two naps of 2 s"
lw_expect_eq "$(cl_clat_lines)" 1 "new: one line"
# ... and recovers when the answer comes within them
cl_setup
cl_dns_off
printf '#!/bin/sh\n[ "$(wc -l <"$LW_TEST/sleeps")" -lt 1 ] || echo "2001:db8:53::1 64:ff9b::c000:aa" >"$LW_TEST/clat/dns"\n' >"$T/on-sleep"
chmod +x "$T/on-sleep"
cl_new
lw_expect_eq "$(cl_adds)" 1 "new: DNS64 answered during the looks, the translation is made"
lw_expect_eq "$(cl_clat_lines)" 1 "new: only the line of the translation ($(cat "$LOG"))"
rm -f "$T/on-sleep"

# a session with no IPv6 DNS server has none to ask
cl_setup
printf '{"up":true,"l3_device":"wwan0","ipv6-address":[{"address":"2001:db8:1::2","mask":64}]}\n' >"$T/ifstatus/wwan_6.json"
cl_tick
lw_expect_eq "$(cat "$C/dns-queries" 2>/dev/null)" "" "no DNS server: nothing asked"
lw_expect_eq "$(cl_clat_lines)" 1 "no DNS server: one line"
grep -q 'the session has no IPv6 DNS server' "$LOG" || lw_fail "no DNS server: line: $(cat "$LOG")"

# unusable answers: not an address of a /96 prefix for ipv4only.arpa, or not an address a prefix can be
# (the low 32 bits must be 192.0.0.170 or 192.0.0.171; unspecified, loopback, mapped IPv4, link-local
# and multicast addresses are no prefix)
for ans in 2001:db8::1 2001:db8::c000:ac 64:ff9b::808:808 2001:db8:1:2:3:c000:aa:0 :: ::1 ::ffff:192.0.0.170 \
    fe80::c000:aa ff02::c000:aa 192.0.0.170 not-an-address 2001:db8::c000:aa::1 \
    2001:db8:::c000:aa 2001:db8:10000::c000:aa 2001:db8::191.256.0.170 \
    2001:db8:0:0:100:0:c000:aa; do
    cl_setup
    cl_dns_off
    cl_dns "$DNS_ADDR" "$ans"
    cl_tick
    lw_expect_eq "$(cl_adds)" 0 "answer $ans: interfaces added"
    lw_expect_eq "$(cl_clat_lines)" 1 "answer $ans: one line"
    grep -q 'is not a /96 prefix the translation can use' "$LOG" || lw_fail "answer $ans: line: $(cat "$LOG")"
done
# an unusable answer next to a usable one: the usable one counts
cl_setup
cl_dns_off
cl_dns "$DNS_ADDR" "2001:db8::1 2001:db8:64::c000:ab"
cl_tick
lw_expect_eq "$(jsonfilter -e '@.ip6prefix' <"$C/added")" 2001:db8:64::/96 "usable answer after an unusable one"
# the text of the line is ASCII whatever the server sent (R29b)
cl_setup
cl_dns_off
cl_dns "$DNS_ADDR" "$(printf 'caf\303\251')"
cl_tick
LC_ALL=C grep -q '[^ -~]' "$LOG" && lw_fail "R29b: a byte outside printable ASCII in the log: $(cat "$LOG")"

# R76c: no DNS64 for a long time, then it answers. The only looks are the events and the ticks; the
# tick after the answer makes the interface, and nothing but that touches netifd
cl_setup
cl_dns_off
for i in 1 2 3 4 5 6; do
    cl_tick
    lw_uptime_add 300
done
lw_expect_eq "$(cl_adds)" 0 "half an hour without DNS64: no interface"
lw_expect_eq "$(cl_clat_lines)" 1 "half an hour without DNS64: one line"
lw_expect_eq "$(wc -l <"$C/dns-queries")" 6 "half an hour without DNS64: one question per tick"
cl_dns "$DNS_ADDR" "$WKP_ANSWER"
cl_tick
lw_expect_eq "$(cl_adds)" 1 "DNS64 answers: the interface is made at the next tick"
lw_expect_eq "$(cl_clat_lines)" 2 "the missing answer, the translation ($(cat "$LOG"))"
lw_expect_eq "$(cat "$T/events")" "" "no restart of wwan while waiting for DNS64 (R76a)"
echo ok
