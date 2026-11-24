# R76b, R76c, D186: the end of a session is cleaned up whether or not a new one follows, and a setup
# that was interrupted (the rules of the stock script are written before its marker) is taken back
# completely; the identity of what is left is kept until netifd confirms the removal, and no
# add_dynamic is sent while it has not finished.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/clat/helpers.inc
. /fw/tests/clat/helpers.inc

# ifdown of wwan with no ifup after it: `down` waits for the end to show in the status, then cleans
cl_setup
cl_tick
cl_translated "setup"
mkdir -p "$CL_DIR"
[ -e "$CL_DIR/active" ] || lw_fail "setup: no mark of a translation"
printf '{"up":false}\n' >"$T/ifstatus/wwan.json"
cl_down
lw_expect_eq "$CL_RC" 0 "down: exit status"
cl_clean_state "ifdown of wwan"
lw_expect_eq "$(cl_clat_lines)" 1 "ifdown: only the line of the session ($(cat "$LOG"))"

# the status still says up for a moment after the event: `down` waits for the confirmed end
cl_setup
cl_tick
cat >"$T/on-sleep" <<EOF2
#!/bin/sh
# wwan goes down at the third nap
[ "\$(wc -l <"\$LW_TEST/sleeps")" -lt 3 ] || echo '{"up":false}' >"\$LW_TEST/ifstatus/wwan.json"
EOF2
chmod +x "$T/on-sleep"
cl_down
cl_clean_state "ifdown, status late"
rm -f "$T/on-sleep"

# the status stays up and IPv6-only (a restart that is already done): nothing is removed
cl_setup
cl_tick
cl_down
cl_translated "ifdown event of a session that is up again"

# the status is up again as another session (the child of the new session has made its record): `down`
# does not hold the lock for its naps, the new session's own check decides about the old translation
cl_setup
cl_tick
cl_session_mark s2
: >"$T/sleeps"
cl_down
lw_expect_eq "$(wc -l <"$T/sleeps")" 0 "ifdown, session already up again as another: no naps"
cl_translated "ifdown, session already up again as another"
[ ! -e "$CL_DIR/cleanup" ] || lw_fail "ifdown, session already up again as another: the mark is left"
cl_new
lw_expect_eq "$(cl_live)" 1 "the new session's check made its own translation"
lw_expect_eq "$(cl_adds)" 2 "the new session's check: interfaces added"
# the same session (the status only lags): the naps are taken
cl_setup
cl_tick
: >"$T/sleeps"
cl_down
lw_expect_eq "$(wc -l <"$T/sleeps")" 10 "ifdown, same session still up: ten naps"

# the status stays unreadable: nothing is removed
cl_setup
cl_tick
rm -f "$T/ifstatus/wwan.json"
cl_down
cl_translated "ifdown, status unreadable"

# a setup interrupted after the rules, before the marker: no marker for the stock teardown, but the
# helper, the device and both rules are there; the next look takes all of it back, the local table's
# rule included, and then goes on to make the translation
cl_setup
cl_outcome interrupted
cl_tick
lw_expect_eq "$(cl_adds)" 1 "interrupted setup: tried once"
cl_clean_state "interrupted setup (no marker)"
cl_setup
cl_outcome interrupted
cl_dns_off
cl_tick
cl_outcome up
cl_dns "$DNS_ADDR" "$WKP_ANSWER"
cl_tick
lw_expect_eq "$(cl_rules | sort)" "from all lookup local pref 1
to 2001:db8:1::464 lookup prelocal pref 0" "interrupted, then a working setup: rules"
lw_expect_eq "$(cl_live)" 1 "interrupted, then a working setup: helper"
# the same, with the end of the session as the reason to clean
cl_setup
cl_outcome interrupted
cl_tick
printf '{"up":false}\n' >"$T/ifstatus/wwan.json"
cl_tick
cl_clean_state "interrupted setup, then the end of the session"
# only the moved rule of the local table is left (the helper and the device gone with a crash of the
# check; the address of the translation is in no file): the rule of the stock script is taken back,
# the table is whole again, and nothing else is guessed at
cl_setup
: >"$CL_DIR/active"
ip -6 rule del from all lookup local
ip -6 rule add from all lookup local pref 1
printf '{"up":false}\n' >"$T/ifstatus/wwan.json"
cl_tick
cl_clean_state "only the moved local rule left"

# netifd has not finished removing the interface: the files that identify the translation stay, and
# no add_dynamic goes out until it is gone
cl_setup
cl_tick
: >"$C/stuck-remove"
cl_session_mark s2
cl_tick
lw_expect_eq "$(cl_removes)" 1 "stuck removal: asked once"
lw_expect_eq "$(cl_adds)" 1 "stuck removal: no new add_dynamic"
[ -e "$CL_PID" ] || lw_fail "stuck removal: the pid file was removed before netifd confirmed"
[ -e "$CL_ANY" ] || lw_fail "stuck removal: the marker was removed before netifd confirmed"
[ -e "$CL_DIR/active" ] || lw_fail "stuck removal: the mark was removed before netifd confirmed"
cl_tick
lw_expect_eq "$(cl_adds)" 1 "stuck removal, next tick: still no add_dynamic"
rm -f "$C/stuck-remove"
cl_tick
lw_expect_eq "$(cl_adds)" 2 "removal done: the translation of the new session is made"
lw_expect_eq "$(cl_live)" 1 "removal done: one helper"
lw_expect_eq "$(cl_nat46)" 464-wwan_6_4 "removal done: one nat46 device"
# the session ends while the setup is going on (the interface never gets up, the child goes with the
# session): not a failure of the setup, so no "did not come up" line; everything is taken away
cl_setup
cl_outcome pending
printf '{"up":false}\n' >"$C/wwan-during-add.json"
cl_tick
lw_expect_eq "$(grep -c "did not come up" "$LOG")" 0 "session ended during the setup: no line about the setup"
lw_expect_eq "$(cl_clat_lines)" 0 "session ended during the setup: no line at all ($(cat "$LOG"))"
cl_clean_state "session ended during the setup"
# the same, with the session still there: the setup did not come up, and the line says so once
cl_setup
cl_outcome pending
cl_tick
lw_expect_eq "$(grep -c "did not come up" "$LOG")" 1 "setup that did not come up: the line"
echo ok
