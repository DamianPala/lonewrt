# R76a, R76c: a translation that is up and was made for this session is not left alone when it cannot
# work any more. (1) The operator's NAT64 is gone or moved while the helper lives: on `tick v4fail`
# (the ladder run found the translation up and got no answer to its IPv4 probe, no ping of the
# check's own) the DNS64 is asked again; another prefix makes the translation again, the same prefix or
# no answer leaves it and says so once per session. A tick whose IPv4 probe passed asks nothing.
# (2) The operator renumbers the link in place: the translation's address is in a /64 the child has
# not any more, so the translation is made again, by the tick and by the hotplug's `update`.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/clat/helpers.inc
. /fw/tests/clat/helpers.inc

cl_tick_fail() { CL_RC=0; lw-clat-check tick v4fail || CL_RC=$?; }
queries() { grep -c . "$C/dns-queries" 2>/dev/null || :; }
helper_pid() { cat "$CL_PID"; }
lines() { grep -c -- "$1" "$LOG" || :; }
child_at() {
    printf '{"up":true,"l3_device":"wwan0","ipv6-address":[%s],"dns-server":["%s"]}\n' "$1" "$DNS_ADDR" \
        >"$T/ifstatus/wwan_6.json"
}

# ---- the same prefix, the NAT64 behind it is down ----------------------------------------------------
cl_setup
cl_tick
lw_expect_eq "$(cl_adds)" 1 "first setup"
p0=$(helper_pid)
q0=$(queries)
cl_tick
lw_expect_eq "$(queries)" "$q0" "the IPv4 probe passed: the DNS64 is not asked"
for i in 1 2 3; do
    cl_tick_fail
    lw_expect_eq "$CL_RC" 0 "tick v4fail $i: exit status"
done
lw_expect_eq "$(queries)" $((q0 + 3)) "tick v4fail asks the DNS64 once each time"
lw_expect_eq "$(cl_adds)" 1 "same prefix: nothing added again"
lw_expect_eq "$(cl_removes)" 0 "same prefix: nothing removed"
lw_expect_eq "$(helper_pid)" "$p0" "same prefix: the same helper"
cl_translated "same prefix"
lw_expect_eq "$(lines 'does not answer on 464-wwan_6_4 and the DNS64 still gives its prefix 64:ff9b::/96')" 1 \
    "same prefix: one line for the session ($(cat "$LOG"))"
lw_expect_eq "$(cl_clat_lines)" 2 "same prefix: the line of the setup and that one, no other ($(cat "$LOG"))"
# the same line is not made again by a session that restarts the child, and a new session says it again
cl_session_mark s2
cl_tick
lw_expect_eq "$(cl_adds)" 2 "a new session: its own translation"
cl_tick_fail
lw_expect_eq "$(lines 'does not answer')" 2 "a new session says it again ($(cat "$LOG"))"
cl_tick_fail
lw_expect_eq "$(lines 'does not answer')" 2 "and only once ($(cat "$LOG"))"

# ---- the NAT64 moved: another prefix -------------------------------------------------------------------
cl_setup
cl_tick
cl_dns_off
cl_dns "$DNS_ADDR" '2001:db8:99:99::c000:aa 2001:db8:99:99::c000:ab'
q0=$(queries)
cl_tick
lw_expect_eq "$(queries)" "$q0" "prefix moved, IPv4 probe passed: not asked, not remade"
lw_expect_eq "$(cl_adds)" 1 "prefix moved, IPv4 probe passed: nothing added"
cl_tick_fail
lw_expect_eq "$(cl_adds)" 2 "prefix moved, IPv4 probe failed: made again"
lw_expect_eq "$(tail -n 1 "$C/added" | jsonfilter -e '@.ip6prefix')" 2001:db8:99:99::/96 "the new prefix"
lw_expect_eq "$(cl_live)" 1 "remade: one helper"
lw_expect_eq "$(cl_nat46)" 464-wwan_6_4 "remade: one nat46 device"
lw_expect_eq "$(cl_rules | grep -c 'lookup prelocal')" 1 "remade: one rule set"
lw_expect_eq "$(cl_removes)" 1 "remade: netifd was asked to remove the old one once"
lw_expect_eq "$(lines 'the DNS64 gives 2001:db8:99:99::/96 now')" 1 "remade: a line says why"
lw_expect_eq "$(lines 'translated IPv4 is up')" 2 "remade: and a line that it is up"
lw_expect_eq "$(cat "$CL_DIR/prefix")" 2001:db8:99:99::/96 "the prefix it was made with is kept"
cl_tick_fail
lw_expect_eq "$(cl_adds)" 2 "the same new prefix again: nothing more"
lw_expect_eq "$(cl_removes)" 1 "the same new prefix again: nothing removed"
lw_expect_eq "$(lines 'DNS64 still gives its prefix 2001:db8:99:99::/96')" 1 "the same new prefix again: the one line"

# A DNS64 answer is valid for the observed session and path. Teardown is asynchronous.
cl_setup
cl_tick
cl_dns_off
cl_dns "$DNS_ADDR" '2001:db8:99:99::c000:aa'
cat >"$T/on-sleep" <<'EOF2'
#!/bin/sh
printf '{"up":true,"data":{"cid_4":17,"pdh_4":4242,"cid_6":18,"pdh_6":3203210530}}\n' >"$LW_TEST/ifstatus/wwan.json"
EOF2
chmod +x "$T/on-sleep"
cl_tick_fail
lw_expect_eq "$(cl_adds)" 1 "native IPv4 returned during teardown: no CLAT add_dynamic"
cl_clean_state "native IPv4 returned during teardown"

# A missing prefix record is possible when an earlier setup was interrupted at publication.
cl_setup
cl_tick
rm -f "$CL_DIR/prefix"
cl_tick_fail
cl_translated "unknown previous prefix"

# ---- the DNS64 does not answer, or answers what the translation cannot use -----------------------------------
cl_setup
cl_tick
p0=$(helper_pid)
cl_dns_off
for i in 1 2; do cl_tick_fail; done
cl_translated "no DNS64 answer"
lw_expect_eq "$(helper_pid)" "$p0" "no DNS64 answer: the same helper"
lw_expect_eq "$(cl_adds)" 1 "no DNS64 answer: nothing added"
lw_expect_eq "$(lines 'translated IPv4 does not answer on 464-wwan_6_4 and the operator')" 1 \
    "no DNS64 answer: one line ($(cat "$LOG"))"
lw_expect_eq "$(lines 'the translation stays, IPv6 works')" 1 "no DNS64 answer: the line says it stays"
cl_setup
cl_tick
cl_dns_off
cl_dns "$DNS_ADDR" '2001:db8:1::1'
cl_tick_fail
cl_translated "an answer that is no prefix"
lw_expect_eq "$(lines 'is not a /96 prefix the translation can use')" 1 "an answer that is no prefix: one line"

# ---- a status that says nothing, a session that is not IPv6-only: nothing is asked ---------------------------------
cl_setup
cl_tick
q0=$(queries)
: >"$T/ifstatus/wwan.unreadable"
cl_tick_fail
rm -f "$T/ifstatus/wwan.unreadable"
lw_expect_eq "$(queries)" "$q0" "wwan unreadable: the DNS64 is not asked"
cl_translated "wwan unreadable"
clat_status=$T/ifstatus/wwan_6_4.json
cp "$clat_status" "$C/valid-status"
printf '{"up":"false"}\n' >"$clat_status"
cl_tick_fail
lw_expect_eq "$(queries)" "$q0" "wwan_6_4 unreadable: the DNS64 is not asked"
cl_translated "wwan_6_4 unreadable"
mv "$C/valid-status" "$clat_status"
lw_session dual
cl_tick_fail
lw_expect_eq "$(queries)" "$q0" "native IPv4: the DNS64 is not asked"
cl_clean_state "native IPv4 takes the translation away"

# ---- the operator renumbers the link in place -----------------------------------------------------------------
cl_setup
cl_tick
lw_expect_eq "$(cat "$CL_ANY")" 2001:db8:1::464 "the translation's address is in the child's /64"
cl_tick
lw_expect_eq "$(cl_adds)" 1 "no renumbering: nothing remade"
child_at '{"address":"2001:db8:2::2","mask":64}'
cl_tick
lw_expect_eq "$(cl_adds)" 2 "the child has another /64: made again"
lw_expect_eq "$(cat "$CL_ANY")" 2001:db8:2::464 "the translation's address follows the child"
lw_expect_eq "$(cl_rules | grep -c 'to 2001:db8:2::464 lookup prelocal')" 1 "the new address has its rule"
lw_expect_eq "$(cl_rules | grep -c 'to 2001:db8:1::464')" 0 "no stale rule for the old /64"
lw_expect_eq "$(cl_rules | grep -c 'lookup prelocal')" 1 "one rule set"
lw_expect_eq "$(cl_live)" 1 "renumbered: one helper"
lw_expect_eq "$(lines 'moved to another /64')" 1 "renumbered: a line says why"
lw_expect_eq "$(cl_nat46)" 464-wwan_6_4 "renumbered: one nat46 device"
cl_tick
lw_expect_eq "$(cl_adds)" 2 "the second look at the new /64: nothing more"

# by the hotplug's own run (the update of the child), with the old address still on the child beside the new
# one: nothing to do
child_at '{"address":"2001:db8:2::2","mask":64},{"address":"2001:db8:3::2","mask":64}'
cl_update
lw_expect_eq "$(cl_adds)" 2 "the child has the old /64 and another one: nothing remade"
child_at '{"address":"2001:db8:3::2","mask":64}'
cl_update
lw_expect_eq "$(cl_adds)" 3 "the update of the child follows the renumbering too"
lw_expect_eq "$(cat "$CL_ANY")" 2001:db8:3::464 "the address of the third /64"
lw_expect_eq "$(cl_rules | grep -c 'lookup prelocal')" 1 "one rule set after the second renumbering"

# the same /64 written another way (zeros spelled out, capitals) is the same /64
child_at '{"address":"2001:DB8:3:0:0:0:0:2","mask":64}'
cl_tick
lw_expect_eq "$(cl_adds)" 3 "the same /64 in the long form: nothing remade"
child_at '{"address":"2001:db8:3::5","mask":128},{"address":"fd00:1::2","mask":64}'
cl_tick
lw_expect_eq "$(cl_adds)" 3 "a /128 of the same /64 and a ULA beside it: nothing remade"

# a renumbering that cannot be acted on (netifd does not confirm the removal) changes nothing
: >"$C/stuck-remove"
child_at '{"address":"2001:db8:4::2","mask":64}'
cl_tick
cl_translated_now() { [ -e "$CL_ANY" ] && [ "$(cl_live)" = 1 ]; }
cl_translated_now || lw_fail "removal not confirmed: the old translation is still all there"
lw_expect_eq "$(cl_adds)" 3 "removal not confirmed: nothing made on top of it"

# a helper that takes an address of its own that is in none of the child's /64s: made again once for
# the child's addresses, not at every look (no loop of setups)
cl_setup
echo 2001:db8:77::464 >"$C/clat-addr"
cl_tick
lw_expect_eq "$(cl_adds)" 1 "an address of its own: first setup"
cl_tick
lw_expect_eq "$(cl_adds)" 2 "an address of its own: made again once"
cl_tick
cl_tick
cl_new
lw_expect_eq "$(cl_adds)" 2 "an address of its own: not made again for the same addresses"
lw_expect_eq "$(lines 'moved to another /64')" 1 "an address of its own: one line"
child_at '{"address":"2001:db8:5::2","mask":64}'
cl_tick
lw_expect_eq "$(cl_adds)" 3 "other addresses of the child: looked at again"

# the update of the child looks at the renumbering and at nothing else: a helper that died, a session that
# is not made yet, a status with no address of the child, a NAT64 that does not answer are for the events
# and for the ladder's run
cl_setup
cl_tick
q0=$(queries)
kill "$(helper_pid)"
for _ in 1 2 3 4 5; do
    [ "$(cl_live)" != 0 ] || break
    /bin/sleep 1
done
child_at '{"address":"2001:db8:9::2","mask":64}'
cl_update
lw_expect_eq "$(cl_adds)" 1 "update with a dead helper and another /64: nothing is made (the helper is the ladder's)"
cl_tick
lw_expect_eq "$(cl_adds)" 2 "the ladder's tick sets the dead helper up again"
printf '{"up":true,"l3_device":"wwan0","ipv6-address":[],"dns-server":["%s"]}\n' "$DNS_ADDR" >"$T/ifstatus/wwan_6.json"
cl_update
cl_tick
lw_expect_eq "$(cl_adds)" 2 "a child status with no address says nothing"
lw_expect_eq "$(queries)" "$((q0 + 1))" "the update asked nothing of the DNS64"
cl_setup
cl_update
lw_expect_eq "$(cl_adds)" 0 "update with no translation: nothing is made"
echo ok
