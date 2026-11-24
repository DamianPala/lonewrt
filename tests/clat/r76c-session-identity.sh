# R76a, R76c: the translation and the notes belong to one session. A session is what qmi.sh's setup
# marked (the handles of the call and a token of that setup), so a new session is told from the old
# one even when the call gets the same handles again and netifd keeps the old wwan_6_4 up: the old
# translation is not taken over, it is made again with what the new session's DNS64 says. A repeated
# ifup of the child inside one session repeats nothing the session already said.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/clat/helpers.inc
. /fw/tests/clat/helpers.inc

jget() { head -n 1 "$1" | jsonfilter -e "$2"; }

# the same handles, a new token, the old interface still up: made again, with the new prefix
cl_setup
cl_dns_off
cl_dns "$DNS_ADDR" '2001:db8:64:64::c000:aa'
cl_tick
lw_expect_eq "$(cl_adds)" 1 "first session: added"
cl_tick
lw_expect_eq "$(cl_adds)" 1 "the same session again: nothing remade"
cl_session_mark s2
cl_dns_off
cl_dns "$DNS_ADDR" '2001:db8:99:99::c000:aa'
cl_new
lw_expect_eq "$(cl_adds)" 2 "second session with the same handles: remade"
lw_expect_eq "$(tail -n 1 "$C/added" | jsonfilter -e '@.ip6prefix')" 2001:db8:99:99::/96 "second session: its own prefix"
lw_expect_eq "$(cl_live)" 1 "second session: one helper"
lw_expect_eq "$(cl_nat46)" 464-wwan_6_4 "second session: one nat46 device"
lw_expect_eq "$(grep -c 'translated IPv4 is up' "$LOG")" 2 "second session: its own line"
lw_expect_eq "$(grep -c 'translated IPv4 stopped' "$LOG")" 0 "a new session is not a stop of the old ($(cat "$LOG"))"
# the same by the tick, the next session again
cl_session_mark s3
cl_dns_off
cl_dns "$DNS_ADDR" '2001:db8:aa:aa::c000:aa'
cl_tick
lw_expect_eq "$(cl_adds)" 3 "third session by the tick: remade"
lw_expect_eq "$(tail -n 1 "$C/added" | jsonfilter -e '@.ip6prefix')" 2001:db8:aa:aa::/96 "third session: its own prefix"

# a session whose setup left no mark (a mark lost with the RAM files) is told by its handles alone
cl_setup
rm -f "$CL_DIR/v6only"
cl_tick
cl_tick
lw_expect_eq "$(cl_adds)" 1 "no mark: one translation, not remade by the second look"

# the once-per-session line: a session with no DNS64 says so once, however often the child comes up
cl_setup
cl_dns_off
cl_new
cl_new
cl_new
cl_tick
lw_expect_eq "$(grep -c 'no IPv4 for the router and the LAN yet' "$LOG")" 1 "repeated ifup of the child, same session ($(cat "$LOG"))"
# a new session says it again
cl_session_mark s2
cl_new
lw_expect_eq "$(grep -c 'no IPv4 for the router and the LAN yet' "$LOG")" 2 "new session: its own line"
# a repeated ifup after the translation came up, then went away, in the same session
cl_dns "$DNS_ADDR" "$WKP_ANSWER"
cl_new
lw_expect_eq "$(cl_adds)" 1 "DNS64 there at last: made"
kill "$(cat "$CL_PID")"
for _ in 1 2 3 4 5; do
    [ "$(cl_live)" != 0 ] || break
    /bin/sleep 1
done
cl_dns_off
cl_new
lw_expect_eq "$(grep -c 'no IPv4 for the router and the LAN yet' "$LOG")" 2 \
    "same session: no repeated DNS64 note after a temporary recovery"
echo ok
