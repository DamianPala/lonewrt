# R76b, R76c: what netifd says about wwan can be unreadable for a moment (a status call that fails or
# times out, a reply that is not JSON, one without the data of the calls, one with half of them). That
# is not a session that ended: it starts no translation and takes none away. Only a confirmed end
# (wwan down) or a confirmed session with native IPv4 (both handles of an IPv4 call) removes one.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/clat/helpers.inc
. /fw/tests/clat/helpers.inc

W=$T/ifstatus/wwan.json
GOOD6='{"up":true,"l3_device":"wwan0","data":{"cid_6":"18","pdh_6":"3203210530"}}'

# unreadable_cases LABEL ACTION: ACTION runs for each kind of unreadable state of wwan
unreadable() {
    case $1 in
        'unreachable ubus') : >"${W%.json}.unreadable" ;;
        empty) : >"$W" ;;
        'not json') echo 'Command failed: Not found' >"$W" ;;
        'no up') echo '{"l3_device":"wwan0","data":{"cid_6":"18","pdh_6":"3203210530"}}' >"$W" ;;
        'no data') echo '{"up":true,"l3_device":"wwan0"}' >"$W" ;;
        'empty data') echo '{"up":true,"l3_device":"wwan0","data":{}}' >"$W" ;;
        'half IPv4') echo '{"up":true,"data":{"cid_4":"17","cid_6":"18","pdh_6":"3203210530"}}' >"$W" ;;
        'half IPv4 pdh') echo '{"up":true,"data":{"pdh_4":"3203210528","cid_6":"18","pdh_6":"3203210530"}}' >"$W" ;;
        'no IPv6 handles') echo '{"up":true,"data":{"cid_6":"18"}}' >"$W" ;;
        'junk handles') echo '{"up":true,"data":{"cid_6":"x","pdh_6":"y z"}}' >"$W" ;;
        # a string is not a JSON boolean: "false" does not say the session ended
        'up is a string "false"') echo '{"up":"false","data":{"cid_6":"18","pdh_6":"3203210530"}}' >"$W" ;;
        'up is a string "true"') echo '{"up":"true","data":{"cid_6":"18","pdh_6":"3203210530"}}' >"$W" ;;
        'up is 0') echo '{"up":0,"data":{"cid_6":"18","pdh_6":"3203210530"}}' >"$W" ;;
        # whole decimal numbers only
        'handle -') echo '{"up":true,"data":{"cid_6":"-","pdh_6":"-"}}' >"$W" ;;
        'handle 1-2') echo '{"up":true,"data":{"cid_6":"18","pdh_6":"32-03"}}' >"$W" ;;
        'handle -5') echo '{"up":true,"data":{"cid_6":"-5","pdh_6":"3203210530"}}' >"$W" ;;
        'IPv4 handles junk') echo '{"up":true,"data":{"cid_4":"1-7","pdh_4":"-","cid_6":"18","pdh_6":"3203210530"}}' >"$W" ;;
        hang) : >"$T/ifstatus/hang" ;;
    esac
}
KINDS='unreachable ubus|empty|not json|no up|no data|empty data|half IPv4|half IPv4 pdh|no IPv6 handles|junk handles|up is a string "false"|up is a string "true"|up is 0|handle -|handle 1-2|handle -5|IPv4 handles junk|hang'

# a translation that works stays through every unreadable state, by tick and by the events
OLDIFS=$IFS
IFS='|'
for k in $KINDS; do
    IFS=$OLDIFS
    cl_setup
    cl_tick
    cl_translated "setup ($k)"
    unreadable "$k"
    cl_tick
    cl_translated "tick, wwan $k"
    cl_new
    cl_translated "new, wwan $k"
    # (a status call that hangs makes `down` wait out its 10 naps of 2 s each: not tried here)
    if [ "$k" != hang ]; then
        cl_down
        cl_translated "down, wwan $k"
    fi
    lw_expect_eq "$(cl_adds)" 1 "wwan $k: interfaces added"
    lw_expect_eq "$(cl_clat_lines)" 1 "wwan $k: log lines ($(cat "$LOG"))"
    rm -f "$T/ifstatus/hang" "${W%.json}.unreadable"
    # the state is readable again and IPv6-only: still the same translation, nothing remade
    printf '%s\n' "$GOOD6" >"$W"
    cl_tick
    cl_translated "back to normal after $k"
    lw_expect_eq "$(cl_adds)" 1 "wwan $k, then normal: interfaces added"
    IFS='|'
done
IFS=$OLDIFS

# an unreadable state starts nothing either: no question, no interface, no line
for k in 'unreachable ubus' 'not json' 'no data' 'half IPv4' 'up is a string "true"' 'handle -' 'IPv4 handles junk'; do
    cl_setup
    unreadable "$k"
    cl_tick
    cl_new
    cl_quiet "no translation yet, wwan $k"
done

# the child unreadable (wwan itself fine): no removal, and nothing new
cl_setup
cl_tick
rm -f "$T/ifstatus/wwan_6.json"
cl_tick
cl_new
cl_translated "wwan_6 unreadable"

# a confirmed end or native IPv4 takes the translation away, with no word
cl_setup
cl_tick
printf '{"up":false}\n' >"$W"
cl_tick
cl_clean_state "wwan down"
cl_setup
cl_tick
lw_session v4
cl_tick
cl_clean_state "native IPv4 (both handles)"
cl_setup
cl_tick
lw_session dual
cl_new
cl_clean_state "dual stack"
lw_expect_eq "$(cl_clat_lines)" 1 "only the line of the first session ($(cat "$LOG"))"
echo ok
