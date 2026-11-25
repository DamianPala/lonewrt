# R76b, R76c: the end of a session is not lost when the check cannot do it at once. A status of
# wwan_6_4 that cannot be read (netifd that does not answer) is not an interface that is gone: no
# state is cleared, no add_dynamic goes out; only netifd's "not found" confirms it. A `down` that finds
# the lock busy for its whole wait leaves a mark that the holder of the lock does when it is done, or
# the next run of wwan-recover does (a builtin test there).
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/clat/helpers.inc
. /fw/tests/clat/helpers.inc

# the translation exists, netifd is removing it, and its status cannot be read meanwhile
cl_setup
cl_tick
cl_translated "setup"
: >"$C/stuck-remove"
cl_session_mark s2
cl_tick
lw_expect_eq "$(cl_removes)" 1 "removing: asked once"
: >"$T/ifstatus/wwan_6_4.unreadable"
rm -f "$C/stuck-remove"
cl_tick
cl_tick
lw_expect_eq "$(cl_adds)" 1 "status unreadable during the removal: no add_dynamic"
[ -e "$CL_PID" ] || lw_fail "status unreadable: the pid file went"
[ -e "$CL_ANY" ] || lw_fail "status unreadable: the marker went"
[ -e "$CL_DIR/active" ] || lw_fail "status unreadable: the mark of a translation went"
lw_expect_eq "$(cl_removes)" 1 "status unreadable: not asked again, nothing assumed"
# the same for the end of a session
cl_setup
cl_tick
: >"$T/ifstatus/wwan_6_4.unreadable"
printf '{"up":false}\n' >"$T/ifstatus/wwan.json"
cl_tick
cl_down
lw_expect_eq "$(cl_live)" 1 "end of session, status unreadable: the helper stays"
[ -e "$CL_DIR/active" ] || lw_fail "end of session, status unreadable: the mark went"
[ -e "$CL_DIR/cleanup" ] || lw_fail "end of session, status unreadable: no retry is scheduled"
cl_tick
[ -e "$CL_DIR/cleanup" ] || lw_fail "end of session, still unreadable: the retry was dropped"
rm -f "$T/ifstatus/wwan_6_4.unreadable"
cl_tick
cl_clean_state "end of session, status readable again"
[ ! -e "$CL_DIR/cleanup" ] || lw_fail "end of session, removed: retry is still scheduled"
# and the state of a translation that is up is not dropped by one unreadable look
cl_setup
cl_tick
: >"$T/ifstatus/wwan_6_4.unreadable"
cl_tick
cl_new
[ -e "$CL_DIR/state" ] || lw_fail "unreadable look: the state was dropped"
lw_expect_eq "$(cl_clat_lines)" 1 "unreadable look: no line about a stop ($(cat "$LOG"))"
lw_expect_eq "$(cl_adds)" 1 "unreadable look: no add_dynamic"
# readable again: nothing was lost
rm -f "$T/ifstatus/wwan_6_4.unreadable"
cl_tick
cl_translated "readable again"

# The first status read says the child is up. An extra read would time out once before recovering.
cl_setup
cl_tick
mkdir -p "$C/bin"
cat >"$C/bin/ifstatus" <<'EOF2'
#!/bin/sh
case $1 in
    wwan_6_4)
        once=$LW_TEST/clat/child-read
        if [ -e "$once" ] && [ ! -s "$once" ]; then
            echo 'failed once' >"$once"
            exit 1
        fi
        [ -e "$once" ] || : >"$once"
        ;;
esac
exec /fw/tests/stubs/ifstatus "$@"
EOF2
chmod +x "$C/bin/ifstatus"
old_path=$PATH
PATH=$C/bin:$PATH
cl_tick
PATH=$old_path
lw_expect_eq "$(cl_adds)" 1 "a healthy snapshot: no restart on a second read"
lw_expect_eq "$(cl_clat_lines)" 1 "a healthy snapshot: no false stopped message"

# `down` finds the lock busy for its whole wait: it leaves the mark, and the one who holds the lock does
# the work when it is done (here: the lock is held by a process that ends later, as a `new` would)
cl_setup
cl_tick
cl_translated "setup"
mkdir -p "$CL_DIR"
printf '{"up":false}\n' >"$T/ifstatus/wwan.json"
(
    exec 9>"$CL_DIR/lock"
    flock -n 9 || exit 1
    # the holder ends at the 30th nap of the check that waits: after the 25 s of the wait
    /bin/sleep 8
) &
holder=$!
/bin/sleep 1
cat >"$T/on-sleep" <<'EOF2'
#!/bin/sh
# the lock is let go at the 26th nap, when `down` has given up
if [ "$(wc -l <"$LW_TEST/sleeps")" -ge 26 ]; then kill "$(cat "$LW_TEST/holder")" 2>/dev/null; fi
EOF2
chmod +x "$T/on-sleep"
echo "$holder" >"$T/holder"
cl_down
lw_expect_eq "$CL_RC" 0 "down at a busy lock: exit status"
rm -f "$T/on-sleep"
wait "$holder" 2>/dev/null || :
[ -e "$CL_DIR/cleanup" ] || lw_fail "down at a busy lock: no mark of the work left"
lw_expect_eq "$(cl_live)" 1 "down at a busy lock: the translation is still there"
# the next run of the check finds a confirmed end and does the work, and the mark goes
cl_tick
cl_clean_state "the next run after a busy lock"
[ ! -e "$CL_DIR/cleanup" ] || lw_fail "the mark is left after the work"

# the holder does it: a check that holds the lock when `down` gives up, does the work before it ends
cl_setup
cl_tick
printf '{"up":false}\n' >"$T/ifstatus/wwan.json"
: >"$CL_DIR/cleanup"
cl_new
cl_clean_state "a check that finds the mark when it is done"
[ ! -e "$CL_DIR/cleanup" ] || lw_fail "the mark is left after the holder did the work"

# a `down` whose reading of the session stays unclear leaves the mark for the ladder, which runs the check
cl_setup
cl_tick
: >"$T/ifstatus/wwan.unreadable"
cl_down
[ -e "$CL_DIR/cleanup" ] || lw_fail "unclear after the naps: no mark for the ladder"
lw_expect_eq "$(cl_live)" 1 "unclear after the naps: nothing removed"
rm -f "$T/ifstatus/wwan.unreadable"
printf '{"up":false}\n' >"$T/ifstatus/wwan.json"
cl_tick
cl_clean_state "the ladder's run after an unclear down"
[ ! -e "$CL_DIR/cleanup" ] || lw_fail "the mark is left after the ladder's run"

# a session that came up again by then: the work is not done, the mark goes
cl_setup
cl_tick
cl_session_mark s2
: >"$CL_DIR/cleanup"
cl_new
[ ! -e "$CL_DIR/cleanup" ] || lw_fail "session up again: the mark is left"

echo ok
