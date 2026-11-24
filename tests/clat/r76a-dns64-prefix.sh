# R76, R76a, R76d, R75, D186, D191: an IPv6-only session whose operator DNS64 answers for
# ipv4only.arpa gets the interface wwan_6_4 on its IPv6 child wwan_6 with the prefix of that answer,
# and only that: the well-known prefix is used when the operator answers with it and never otherwise,
# the question goes to the session's own IPv6 DNS servers (a second one when the first is silent),
# not to the router's resolver, the interface is in the zone of wwan, and there is one syslog line.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/clat/helpers.inc
. /fw/tests/clat/helpers.inc

A6='"ipv6-address":[{"address":"2001:db8:1::2","mask":64}],'

# jget FILE PATH: one value of the first JSON object of the file
jget() { head -n 1 "$1" | jsonfilter -e "$2"; }

# the operator's own prefix
cl_setup
cl_dns_off
cl_dns "$DNS_ADDR" '2001:db8:64:64::c000:aa 2001:db8:64:64::c000:ab'
cl_tick
lw_expect_eq "$CL_RC" 0 "operator prefix: exit status"
lw_expect_eq "$(cl_adds)" 1 "operator prefix: interfaces added"
A=$C/added
lw_expect_eq "$(jget "$A" '@.name')" wwan_6_4 "R76d: interface name"
lw_expect_eq "$(jget "$A" '@.proto')" 464xlat "proto"
lw_expect_eq "$(jget "$A" '@.ifname')" @wwan_6 "attach point: the IPv6 child"
lw_expect_eq "$(jget "$A" '@.tunlink')" wwan_6 "tunlink"
lw_expect_eq "$(jget "$A" '@.ip6prefix')" 2001:db8:64:64::/96 "R76a: the prefix of the operator's answer"
lw_expect_eq "$(jget "$A" '@.zone')" wan "R75: the zone"
lw_expect_eq "$(cat "$C/dns-queries")" "nslookup -type=AAAA ipv4only.arpa $DNS_ADDR" "R76a: one question, to the session's DNS"
lw_expect_eq "$(cl_live)" 1 "one helper"
lw_expect_eq "$(cl_nat46)" 464-wwan_6_4 "the device of R76d"
grep -q 'remote.v6 2001:db8:64:64::/96' "$CL_NAT" || lw_fail "nat46 has not the operator's prefix: $(cat "$CL_NAT")"
lw_expect_eq "$(grep -c 'translated IPv4 is up on 464-wwan_6_4, prefix 2001:db8:64:64::/96' "$LOG")" 1 "one line: up"
lw_expect_eq "$(cl_clat_lines)" 1 "log lines"
# nothing of the modem and nothing of the link layer: no ifup (R76a), and the stock DHCPv6 script
# is not involved (the image's qmi.sh switches its interface off)
lw_expect_eq "$(cat "$T/events")" "" "no ifup or ifdown"
# a second look at a healthy translation asks nothing and adds nothing
cl_tick
lw_expect_eq "$CL_RC" 0 "second look"
lw_expect_eq "$(cl_adds)" 1 "second look: interfaces added"
lw_expect_eq "$(wc -l <"$C/dns-queries")" 1 "second look: DNS64 queries"
lw_expect_eq "$(cl_clat_lines)" 1 "second look: log lines"

# the same through the hotplug's mode
cl_setup
cl_new
lw_expect_eq "$CL_RC" 0 "new: exit status"
lw_expect_eq "$(cl_adds)" 1 "new: interfaces added"

# the well-known prefix, because the operator answers with it (not because it is assumed); the zone
# is the one of the data of wwan
cl_setup
printf '{"up":true,"l3_device":"wwan0","data":{"cid_6":"18","pdh_6":"3203210530","zone":"lte"}}\n' \
    >"$T/ifstatus/wwan.json"
cl_tick
lw_expect_eq "$(jget "$C/added" '@.ip6prefix')" 64:ff9b::/96 "answer 64:ff9b::c000:aa"
lw_expect_eq "$(jget "$C/added" '@.zone')" lte "the zone of wwan"

# the second answer of the pair, an answer that comes in a different order, and one written in full
# are as good
for ans in '64:ff9b::c000:ab' '64:ff9b::192.0.0.170' '64:ff9b::c000:ab 64:ff9b::c000:aa' \
    '2001:db8:0:1:0:0:c000:00aa'; do
    cl_setup
    cl_dns_off
    cl_dns "$DNS_ADDR" "$ans"
    cl_tick
    lw_expect_eq "$(cl_adds)" 1 "answer $ans: added"
done
lw_expect_eq "$(jget "$C/added" '@.ip6prefix')" 2001:db8:0:1::/96 "an address in full is shortened"

# the first DNS server does not answer, the second does
cl_setup
printf '{"up":true,"l3_device":"wwan0",'"$A6"'"dns-server":["%s","%s"]}\n' "$DNS_ADDR" "$DNS_ADDR2" \
    >"$T/ifstatus/wwan_6.json"
cl_dns_off
cl_dns "$DNS_ADDR" down
cl_dns "$DNS_ADDR2" "$WKP_ANSWER"
cl_tick
lw_expect_eq "$(cat "$C/dns-queries")" "nslookup -type=AAAA ipv4only.arpa $DNS_ADDR
nslookup -type=AAAA ipv4only.arpa $DNS_ADDR2" "both servers in turn"
lw_expect_eq "$(jget "$C/added" '@.ip6prefix')" 64:ff9b::/96 "second server's answer"

# only the IPv6 servers of the child are asked: an IPv4 server of the session is not, nor is the
# server list of the parent wwan
cl_setup
printf '{"up":true,"l3_device":"wwan0",'"$A6"'"dns-server":["192.0.2.53","%s"]}\n' "$DNS_ADDR" \
    >"$T/ifstatus/wwan_6.json"
printf '{"up":true,"l3_device":"wwan0","dns-server":["2001:db8:99::1"],"data":{"cid_6":"18","pdh_6":"3203210530"}}\n' \
    >"$T/ifstatus/wwan.json"
cl_tick
lw_expect_eq "$(cat "$C/dns-queries")" "nslookup -type=AAAA ipv4only.arpa $DNS_ADDR" "IPv6 servers of the child only"

# the query takes the checked path: busybox nslookup cannot be given a source or a device, so a host
# route to the server through the child's gateway and device exists for the time of the query (ip's
# calls are kept in route-calls) and is gone after it
cl_setup
printf '{"up":true,"l3_device":"wwan0",'"$A6"'"route":[{"target":"::","mask":0,"nexthop":"fe80::1"}],"dns-server":["%s"]}\n' \
    "$DNS_ADDR" >"$T/ifstatus/wwan_6.json"
cl_tick
lw_expect_eq "$(cat "$C/route-calls")" "ip route add $DNS_ADDR/128 via fe80::1 dev wwan0 metric 1
ip route del $DNS_ADDR/128 via fe80::1 dev wwan0 metric 1" "a host route for the query, and removed"
lw_expect_eq "$(cat "$C/hostroutes")" "" "no host route is left"
lw_expect_eq "$(cat "$C/route-gets")" "ip -6 route get $DNS_ADDR" "the route the query takes is looked up with no source, as the query is made"
lw_expect_eq "$(cl_adds)" 1 "host route: added"

# no default route with a gateway (an on-link one): the host route is made on the device alone
cl_setup
cl_tick
lw_expect_eq "$(head -n 1 "$C/route-calls")" "ip route add $DNS_ADDR/128 dev wwan0 metric 1" "no gateway: the device alone"

# a default route of another uplink or a tunnel (what the VM measured: 2 packets on br-lan, 0 on
# wwan0) does not matter: the host route is the longest match, the query is asked
cl_setup
lw_route "$DNS_ADDR" wg0
cl_tick
lw_expect_eq "$(cat "$C/dns-queries")" "nslookup -type=AAAA ipv4only.arpa $DNS_ADDR" "a default route over a tunnel: asked"
lw_expect_eq "$(cl_adds)" 1 "a default route over a tunnel: the translation is made"
lw_expect_eq "$(cat "$C/hostroutes")" "" "a default route over a tunnel: no host route is left"

# a policy that sends the query elsewhere whatever the host route says: the lookup shows it, the
# server is not asked, the host route is taken away again
cl_setup
lw_route "$DNS_ADDR" wg0
: >"$C/hostroutes-ignored"
cl_tick
lw_expect_eq "$(cat "$C/dns-queries" 2>/dev/null)" "" "a policy that diverts the query: nothing asked"
lw_expect_eq "$(cl_adds)" 0 "a policy that diverts the query: no interface"
lw_expect_eq "$(cat "$C/hostroutes")" "" "a policy that diverts the query: the host route is taken away"
grep -q "does not leave on wwan0" "$LOG" || lw_fail "a policy that diverts the query: line: $(cat "$LOG")"

# a host route to the server that is already there and leaves elsewhere (another uplink's, a
# tunnel's) is not touched and the server is not asked
cl_setup
echo "$DNS_ADDR wg0 fe80::9" >"$C/hostroutes"
cl_tick
lw_expect_eq "$(cat "$C/dns-queries" 2>/dev/null)" "" "a host route elsewhere: nothing asked"
lw_expect_eq "$(cl_adds)" 0 "a host route elsewhere: no interface"
lw_expect_eq "$(cat "$C/hostroutes")" "$DNS_ADDR wg0 fe80::9" "a host route elsewhere: left as it was"
[ ! -e "$C/route-calls" ] || lw_fail "a host route elsewhere: ip was asked to change routes: $(cat "$C/route-calls")"
grep -q "does not leave on wwan0" "$LOG" || lw_fail "a host route elsewhere: line: $(cat "$LOG")"

cl_setup
echo "$DNS_ADDR wg0 fe80::9" >"$C/hostroutes"
: >"$C/route-show-fails"
cl_tick
lw_expect_eq "$(cat "$C/hostroutes")" "$DNS_ADDR wg0 fe80::9" "route inspection failed: pre-existing route preserved"
[ ! -e "$C/route-calls" ] || lw_fail "route inspection failed: ip was asked to change routes"

# one that is there and leaves on the child's device is used, and left in place
cl_setup
echo "$DNS_ADDR wwan0 fe80::1" >"$C/hostroutes"
cl_tick
lw_expect_eq "$(cat "$C/dns-queries")" "nslookup -type=AAAA ipv4only.arpa $DNS_ADDR" "a host route on the device: asked"
lw_expect_eq "$(cat "$C/hostroutes")" "$DNS_ADDR wwan0 fe80::1" "a host route on the device: left in place"
[ ! -e "$C/route-calls" ] || lw_fail "a host route on the device: ip was asked to change routes: $(cat "$C/route-calls")"

# the route cannot be made: not asked, one line says so
cl_setup
: >"$C/route-add-fails"
cl_tick
lw_expect_eq "$(cat "$C/dns-queries" 2>/dev/null)" "" "no route could be made: nothing asked"
lw_expect_eq "$(cl_adds)" 0 "no route could be made: no interface"
grep -q "could be made on wwan0" "$LOG" || lw_fail "no route could be made: line: $(cat "$LOG")"

# the host route goes also when the server does not answer, and when the check is cut in the middle
cl_setup
cl_dns_off
cl_dns "$DNS_ADDR" down
cl_tick
lw_expect_eq "$(cat "$C/hostroutes")" "" "no answer: the host route is taken away"

cl_setup
: >"$C/route-del-fails-once"
cl_tick
lw_expect_eq "$(cat "$C/hostroutes")" "" "delete failed once: exit retried with the same route"
lw_expect_eq "$(cl_adds)" 0 "delete failed once: no translation started before route cleanup"
cl_setup
cl_dns_off
cl_dns "$DNS_ADDR" hang
lw-clat-check tick &
chk=$!
i=0
while [ ! -s "$C/hostroutes" ] && [ "$i" -lt 20 ]; do i=$((i + 1)); /bin/sleep 1; done
[ -s "$C/hostroutes" ] || lw_fail "cut in the middle: the host route was never made"
kill -TERM "$chk"
wait "$chk" 2>/dev/null || :
lw_expect_eq "$(cat "$C/hostroutes")" "" "cut in the middle: the host route is taken away"

# the child has several addresses: the host route is for the query whichever source the kernel picks
cl_setup
printf '{"up":true,"l3_device":"wwan0","ipv6-address":[{"address":"2001:db8:1::2","mask":64},{"address":"2001:db8:1::3","mask":64}],"dns-server":["%s"]}\n' \
    "$DNS_ADDR" >"$T/ifstatus/wwan_6.json"
cl_tick
lw_expect_eq "$(cl_adds)" 1 "two addresses: added"

# a link-local server needs a scope id the query cannot be given: refused with a line, not asked
cl_setup
printf '{"up":true,"l3_device":"wwan0",%s"dns-server":["fe80::1","fe80::2"]}\n' "$A6" >"$T/ifstatus/wwan_6.json"
cl_tick
lw_expect_eq "$(cat "$C/dns-queries" 2>/dev/null)" "" "link-local servers: nothing asked"
lw_expect_eq "$(cl_adds)" 0 "link-local servers: no interface"
grep -q "link-local, which is not asked" "$LOG" || lw_fail "link-local servers: line: $(cat "$LOG")"
# a link-local server beside a global one: the global one is asked
cl_setup
printf '{"up":true,"l3_device":"wwan0",'"$A6"'"dns-server":["fe80::1","%s"]}\n' "$DNS_ADDR" >"$T/ifstatus/wwan_6.json"
cl_tick
lw_expect_eq "$(cat "$C/dns-queries")" "nslookup -type=AAAA ipv4only.arpa $DNS_ADDR" "link-local and global: the global one"
lw_expect_eq "$(cl_adds)" 1 "link-local and global: added"
# the child has no address yet: not ready, nothing asked
cl_setup
printf '{"up":true,"l3_device":"wwan0","dns-server":["%s"]}\n' "$DNS_ADDR" >"$T/ifstatus/wwan_6.json"
cl_tick
cl_quiet "child without an address"
# the child's device or address changes while the answer is pending: the prefix is not used
cl_setup
printf '{"up":true,"l3_device":"wwan1",'"$A6"'"dns-server":["%s"]}\n' "$DNS_ADDR" >"$C/wwan_6-during-dns.json"
cl_tick
lw_expect_eq "$(cl_adds)" 0 "device of the child changed during the question: no interface"
cl_setup
printf '{"up":true,"l3_device":"wwan0","ipv6-address":[{"address":"2001:db8:1::99","mask":64}],"dns-server":["%s"]}\n' \
    "$DNS_ADDR" >"$C/wwan_6-during-dns.json"
cl_tick
lw_expect_eq "$(cl_adds)" 0 "address of the child changed during the question: no interface"

# the child is not up yet (an IPv6-only start that is still settling): nothing to ask, nothing to say
cl_setup
printf '{"up":false}\n' >"$T/ifstatus/wwan_6.json"
cl_tick
cl_quiet "child not up"
rm -f "$T/ifstatus/wwan_6.json"
cl_tick
cl_quiet "no child"

# the session's DNS64 answers while the session is replaced: the prefix of the old session is not used
cl_setup
printf '{"up":true,"l3_device":"wwan0","data":{"cid_6":"31","pdh_6":"5550001"}}\n' >"$C/wwan-during-dns.json"
cl_tick
lw_expect_eq "$(cl_adds)" 0 "session replaced during the question: no interface"
lw_expect_eq "$(cl_clat_lines)" 0 "session replaced during the question: no line"
cl_clean_state "session replaced during the question"
echo ok
