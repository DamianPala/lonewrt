# R76c: the translation is taken down only when something better is ready, and only what is ours.
# (1) The decision that the operator renumbered the link is made on the whole, validated set of /64
# prefixes of the child's addresses; a list that is cut, unreadable or has an entry that is no IPv6
# address keeps the translation, and the limit on remaking it (one remake for one set) goes by the
# set of prefixes, not by the addresses in the order netifd lists them.
# (2) A renumbering does not take the translation away before its replacement is known: the stored
# prefix of the translation (the NAT64 behind it did not change), or a DNS64 answer; the session is
# read again after netifd removed the old one.
# (3) The stock teardown of 464xlat.sh signals whatever pid its pid file names: the file is made to
# name our own helper or to go before any planned teardown.
# (4) A teardown that was cut short can be taken up again: a host route of a DNS query that was under
# way, an address marker whose rule could not be deleted, a helper that is still exiting.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/clat/helpers.inc
. /fw/tests/clat/helpers.inc

lines() { grep -c -- "$1" "$LOG" || :; }
child_at() {
    printf '{"up":true,"l3_device":"wwan0","ipv6-address":[%s],"dns-server":["%s"]}\n' "$1" "$DNS_ADDR" \
        >"$T/ifstatus/wwan_6.json"
}
a() { printf '{"address":"%s","mask":64}' "$1"; }

# ---- 1: the set of the child's /64s -------------------------------------------------------------------
# an address list that cannot be trusted keeps the translation, by the hotplug's run and by the ladder's
for body in \
    "$(a invalid:value)" \
    "$(a 2001:db8:9::2),$(a invalid:value)" \
    "$(a 2001:db8:9::2),{\"mask\":64}" \
    "$(a 2001:db8:9::2/64)" \
    "$(a 1:2:3:4:5:6:7:8:9)" \
    "$(a 2001:db8:::1)" \
    "$(a 2001:db8:1::g)" \
    "$(a 2001:db8:12345::1)" \
    '{"address":"2001:db8:9::2\n2001:db8:8::2","mask":64},{"mask":64}' \
    '{"address":7,"mask":64}'; do
    cl_setup
    cl_tick
    child_at "$body"
    cl_update
    cl_tick
    lw_expect_eq "$(cl_removes)" 0 "an address list that is not whole ($body): nothing removed"
    lw_expect_eq "$(cl_adds)" 1 "an address list that is not whole ($body): nothing added"
    cl_translated "an address list that is not whole ($body)"
done
# no ipv6-address field at all, or one that is no list
cl_setup
cl_tick
printf '{"up":true,"l3_device":"wwan0","dns-server":["%s"]}\n' "$DNS_ADDR" >"$T/ifstatus/wwan_6.json"
cl_update
cl_tick
lw_expect_eq "$(cl_removes)" 0 "no address field: nothing removed"
printf '{"up":true,"l3_device":"wwan0","ipv6-address":"2001:db8:9::2","dns-server":["%s"]}\n' "$DNS_ADDR" >"$T/ifstatus/wwan_6.json"
cl_update
lw_expect_eq "$(cl_removes)" 0 "an address field that is no list: nothing removed"

# the address that matches is the ninth: it counts
cl_setup
cl_tick
list=''
for n in 1 2 3 4 5 6 7 8; do list="$list$(a "2001:db8:a$n::1"),"; done
child_at "$list$(a 2001:db8:1::77)"
cl_update
cl_tick
lw_expect_eq "$(cl_removes)" 0 "the matching address is the ninth: nothing removed"
# ... and twelve addresses of other /64s is a renumbering
list=''
for n in 1 2 3 4 5 6 7 8 9 10 11 12; do list="$list$(a "2001:db8:b$n::1"),"; done
child_at "${list%,}"
cl_update
lw_expect_eq "$(cl_adds)" 2 "twelve addresses, none in the translation's /64: made again"

# the same /64 written in any way, in any order, with any interface identifier, is no change
cl_setup
cl_tick
child_at "$(a 2001:DB8:1:0:0:0:5:6),$(a fd00:1::9),$(a 2001:db8:1::abcd)"
cl_update
cl_tick
lw_expect_eq "$(cl_removes)" 0 "the same /64 in other forms, with a ULA beside: nothing removed"

# a helper with an address of its own (in none of the child's /64s): made again once for one set of
# prefixes; a change of order, of interface identifiers or of a repeated prefix is no new set
cl_setup
echo 2001:db8:77::464 >"$C/clat-addr"
cl_tick
lw_expect_eq "$(cl_adds)" 1 "own address: first setup"
child_at "$(a 2001:db8:5::2),$(a 2001:db8:6::2)"
cl_tick
lw_expect_eq "$(cl_adds)" 2 "own address: made again for the first set"
child_at "$(a 2001:db8:6::9),$(a 2001:db8:5::7),$(a 2001:db8:6::aa)"
cl_tick
cl_update
child_at "$(a 2001:db8:5::1),$(a 2001:db8:6::3)"
cl_update
lw_expect_eq "$(cl_adds)" 2 "own address: order, identifiers and repeats are the same set"
child_at "$(a 2001:db8:5::1),$(a 2001:db8:6::3),$(a 2001:db8:7::1)"
cl_update
lw_expect_eq "$(cl_adds)" 3 "own address: a third /64 is another set"
cl_dns_off
cl_dns "$DNS_ADDR" '2001:db8:99:99::c000:aa'
lw-clat-check tick v4fail
lw_expect_eq "$(tail -n 1 "$C/added" | jsonfilter -e '@.ip6prefix')" 2001:db8:99:99::/96 \
    "deduplicating the /64 must not suppress DNS64 recovery"

# ---- 2: nothing is taken away before its replacement is known -----------------------------------------
# a new /64 and a DNS64 that is silent: the stored prefix of the translation is the replacement
cl_setup
cl_tick
cl_dns_off
child_at "$(a 2001:db8:2::2)"
cl_update
lw_expect_eq "$(cl_adds)" 2 "new /64, DNS64 silent: made again with the stored prefix"
lw_expect_eq "$(tail -n 1 "$C/added" | jsonfilter -e '@.ip6prefix')" 64:ff9b::/96 "the stored prefix"
lw_expect_eq "$(cat "$CL_ANY")" 2001:db8:2::464 "the address is in the new /64"
lw_expect_eq "$(cl_removes)" 1 "the old one was removed once"
# no stored prefix and a silent DNS64: nothing to make a new one with, the old one stays
cl_setup
cl_tick
rm -f "$CL_DIR/prefix"
cl_dns_off
child_at "$(a 2001:db8:2::2)"
cl_update
cl_tick
lw_expect_eq "$(cl_removes)" 0 "new /64, no prefix of any kind: the old translation stays"
lw_expect_eq "$(cl_adds)" 1 "new /64, no prefix of any kind: nothing added"
cl_translated "new /64, no prefix of any kind"
# ... the next event with an answer makes it
cl_dns "$DNS_ADDR" "$WKP_ANSWER"
cl_update
lw_expect_eq "$(cl_adds)" 2 "new /64, the DNS64 answers at the next event: made"
# a stored prefix that is no prefix: not a replacement
cl_setup
cl_tick
echo '2001::::/96' >"$CL_DIR/prefix"
cl_dns_off
child_at "$(a 2001:db8:2::2)"
cl_update
lw_expect_eq "$(cl_removes)" 0 "a stored prefix that is no prefix: the old translation stays"
# the ladder's run after a PLAT move and a new /64 together: the confirmed prefix is the one
cl_setup
cl_tick
cl_dns_off
cl_dns "$DNS_ADDR" '2001:db8:99:99::c000:aa 2001:db8:99:99::c000:ab'
child_at "$(a 2001:db8:2::2)"
lw-clat-check tick v4fail
lw_expect_eq "$(tail -n 1 "$C/added" | jsonfilter -e '@.ip6prefix')" 2001:db8:99:99::/96 "tick v4fail with a new /64: the DNS64's new prefix"
# the session changes while netifd removes the old interface: nothing is made
cl_setup
cl_tick
child_at "$(a 2001:db8:2::2)"
cat >"$T/on-sleep" <<'EOF2'
#!/bin/sh
printf '{"up":true,"data":{"cid_4":17,"pdh_4":4242,"cid_6":18,"pdh_6":3203210530}}\n' >"$LW_TEST/ifstatus/wwan.json"
EOF2
chmod +x "$T/on-sleep"
cl_update
lw_expect_eq "$(cl_adds)" 1 "renumbered, native IPv4 came during the removal: no add_dynamic"
cl_clean_state "renumbered, native IPv4 came during the removal"
# ... or the child's addresses change again
cl_setup
cl_tick
child_at "$(a 2001:db8:2::2)"
cat >"$T/on-sleep" <<'EOF2'
#!/bin/sh
printf '{"up":true,"l3_device":"wwan0","ipv6-address":[{"address":"2001:db8:3::2","mask":64}],"dns-server":["2001:db8:53::1"]}\n' >"$LW_TEST/ifstatus/wwan_6.json"
EOF2
chmod +x "$T/on-sleep"
cl_update
lw_expect_eq "$(cl_adds)" 1 "renumbered, the child changed again during the removal: no add_dynamic with the old picture"
rm -f "$T/on-sleep"
cl_tick
lw_expect_eq "$(cl_adds)" 2 "the next run makes it for the child as it is now"
lw_expect_eq "$(cat "$CL_ANY")" 2001:db8:3::464 "and the address is in the third /64"

# ---- 3: the stock teardown signals the pid its file names ---------------------------------------------
# the marker is there (the stock teardown works), the pid file names another device's helper
cl_setup
cl_tick
cl_fake_helper 464-other0 wwan9 2001:db8:77::/96
echo "$FAKE" >"$CL_PID"
printf '{"up":false}\n' >"$T/ifstatus/wwan.json"
cl_new
kill -0 "$FAKE" 2>/dev/null || lw_fail "the stock teardown with the marker signalled another device's helper"
lw_expect_eq "$(cl_live)" 1 "the original owned helper was stopped despite the overwritten PID file"
kill "$FAKE" 2>/dev/null || :
# the same for the teardown of a renumbering and of a moved prefix
cl_setup
cl_tick
cl_fake_helper 464-other0 wwan9 2001:db8:77::/96
echo "$FAKE" >"$CL_PID"
child_at "$(a 2001:db8:2::2)"
cl_update
kill -0 "$FAKE" 2>/dev/null || lw_fail "the teardown of a renumbering signalled another device's helper"
cl_tick
lw_expect_eq "$(cl_live)" 2 "renumbering leaves only the new and the foreign helper"
kill "$FAKE" 2>/dev/null || :
# a pid file that names a process whose argv has the right words in one argument with a newline in it
cl_setup
cl_tick
CL_ARGV0="$(printf '464xlatcfg\n464-wwan_6_4')" cl_fake_helper wwan0 2001:db8:77::/96
echo "$FAKE" >"$CL_PID"
printf '{"up":false}\n' >"$T/ifstatus/wwan.json"
cl_new
kill -0 "$FAKE" 2>/dev/null || lw_fail "a process with a newline in its argv[0] was taken for our helper"
kill "$FAKE" 2>/dev/null || :
# a pid file that names a process that is gone: removed, nothing signalled
cl_setup
cl_tick
echo 999999 >"$CL_PID"
printf '{"up":false}\n' >"$T/ifstatus/wwan.json"
cl_new
[ ! -e "$CL_PID" ] || lw_fail "the stale pid file is left"
# our own helper in the pid file: the teardown stops it
cl_setup
cl_tick
printf '{"up":false}\n' >"$T/ifstatus/wwan.json"
cl_new
cl_clean_state "our own helper in the pid file"

# ---- 4: a teardown that was cut short -------------------------------------------------------------------
# the host route of a DNS query is written down before it is made: a check killed in between leaves a
# record that the next run takes up, and the route goes
cl_setup
cl_tick
echo "$DNS_ADDR wwan0 fe80::1" >"$C/hostroutes"
echo "$DNS_ADDR wwan0 fe80::1" >"$CL_DIR/pin"
cl_tick
[ ! -s "$C/hostroutes" ] || lw_fail "the host route of a cut query is left: $(cat "$C/hostroutes")"
[ ! -e "$CL_DIR/pin" ] || lw_fail "the record of the host route is left"
cl_translated "a cut query's route taken back"
# An unreadable route table is no confirmation that the recorded route went away.
cl_setup
cl_tick
echo "$DNS_ADDR wwan0 fe80::1" >"$C/hostroutes"
echo "$DNS_ADDR wwan0 fe80::1" >"$CL_DIR/pin"
: >"$C/route-show-fails"
lw-clat-check tick v4fail
[ -e "$CL_DIR/pin" ] || lw_fail "failed route inspection discarded the cleanup record"
rm -f "$C/route-show-fails"
cl_tick
[ ! -s "$C/hostroutes" ] || lw_fail "the next check did not retry the failed route cleanup"
[ ! -e "$CL_DIR/pin" ] || lw_fail "route cleanup did not clear its record"
# A route that replaced the temporary one on the same device is owned elsewhere.
cl_setup
cl_tick
echo "$DNS_ADDR wwan0 fe80::9" >"$C/hostroutes"
echo "$DNS_ADDR wwan0 fe80::1" >"$CL_DIR/pin"
lw-clat-check tick v4fail
lw_expect_eq "$(cat "$C/hostroutes")" "$DNS_ADDR wwan0 fe80::9" "a replacement route survives recovery"
[ ! -e "$CL_DIR/pin" ] || lw_fail "the record was kept for another route"
# the record of an ordinary query is gone when the query is done
cl_setup
cl_tick
[ ! -e "$CL_DIR/pin" ] || lw_fail "the record of the host route is left after an ordinary query"
# the address marker stays when the rule it stands for could not be deleted; the next run finishes
cl_setup
cl_tick
: >"$C/rule-del-fails"
printf '{"up":false}\n' >"$T/ifstatus/wwan.json"
printf '{"up":false}\n' >"$T/ifstatus/wwan_6.json"
mv "$T/ifstatus/wwan_6_4.json" "$T/ifstatus/wwan_6_4.gone" 2>/dev/null || :
cl_new
[ -e "$CL_ANY" ] || lw_fail "the marker was removed although its rule could not be deleted"
[ -e "$CL_DIR/active" ] || lw_fail "the mark of the translation was removed although its rule is left"
rm -f "$C/rule-del-fails"
cl_new
cl_clean_state "the next run after the failed rule deletion"
# Stock teardown can remove the address marker even if the rule deletion fails.
cl_setup
cl_tick
: >"$C/rule-del-fails"
printf '{"up":false}\n' >"$T/ifstatus/wwan.json"
cl_down
[ -e "$CL_DIR/active" ] || lw_fail "stock teardown forgot an undeleted rule"
rm -f "$C/rule-del-fails"
cl_tick
cl_clean_state "retry after stock teardown could not delete the rule"

# The old helper can outlast the first worker's wait, with its stock PID file already removed.
cl_setup
cl_tick
old_pid=$(cat "$CL_PID")
kill -STOP "$old_pid"
child_at "$(a 2001:db8:2::2)"
: >"$T/sleeps"
timeout -k 2 20 lw-clat-check update || lw_fail "the first wait for the old helper did not return"
lw_expect_eq "$(cl_adds)" 1 "the old helper is still exiting: no second setup yet"
lw_expect_eq "$(wc -l <"$T/sleeps")" 6 "one netifd nap and five helper naps"
flock -n "$CL_DIR/lock" true || lw_fail "the first worker kept the lock"
: >"$T/sleeps"
timeout -k 2 20 lw-clat-check tick || lw_fail "the next wait for the old helper did not return"
lw_expect_eq "$(cl_adds)" 1 "a new worker also waits for the old helper"
lw_expect_eq "$(wc -l <"$T/sleeps")" 5 "the retry also waits at most five naps"
flock -n "$CL_DIR/lock" true || lw_fail "the second worker kept the lock"
kill -CONT "$old_pid"
cl_tick
lw_expect_eq "$(cl_adds)" 2 "the old helper is gone: the setup follows"
lw_expect_eq "$(cl_live)" 1 "one helper"
echo ok
