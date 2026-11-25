# R74f, R74c, R49i: a loss of the IPv6 call inside the modem, with IPv4 healthy, gives no netifd event.
# The watcher reads the state of the IPv6 call while IPv4 is healthy; a confirmed disconnect (data
# status and settings) switches the LAN's IPv6 off through the flag of lan6.sh and one reload of
# odhcpd; the call connected again switches it on. An unreadable answer changes nothing. A session
# without an IPv6 call makes no call for it at all. IPv4 is never touched.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc

LAN6CALLS=$T/lan6-calls
V6D="-s -d /tmp/cdc-wdm0 -t 3000 --set-client-id wds,18 --get-data-status"
V6S="-s -d /tmp/cdc-wdm0 -t 3000 --set-client-id wds,18 --get-current-settings"
V4D="-s -d /tmp/cdc-wdm0 -t 3000 --set-client-id wds,17 --get-data-status"
FLAG=/var/run/lw-linkwatch/v6lost
MARK=/var/run/lw-linkwatch/v6reload

setup() {
    lk_setup
    LW_LINKWATCH_LAN6=/fw/tests/linkwatch/stubs/lan6-init
    export LW_LINKWATCH_LAN6
    rm -f "$LAN6CALLS" "$T/lan6-fail" "$T/lan6-hang"
    lk_dual
}
lan6_calls() { cat "$LAN6CALLS" 2>/dev/null || :; }

# a healthy IPv6 call: one more read per pass, nothing written, no reload
setup
lw-linkwatch once
lw_expect_eq "$(cat "$CALLS")" "$V4D
$V6D" "R74f a healthy dual-stack pass reads both calls"
lw_expect_eq "$(lan6_calls)" "" "R74f healthy IPv6: no reload"
lw_expect_eq "$(lk_lines)" "" "R74f healthy IPv6: no line"
[ ! -e "$FLAG" ] || lw_fail "R74f flag written while IPv6 was healthy"

# the call is lost inside the modem, IPv4 stays: the flag, one reload, one line, IPv4 untouched
echo down >"$T/uqmi/session-18"
: >"$CALLS"
lw-linkwatch once
lw_expect_eq "$(cat "$CALLS")" "$V4D
$V6D
$V6S" "R74f lost call: status, then the settings that confirm it"
lw_expect_eq "$(lan6_calls)" "reload lan6 flag=18/3203210529 -" "R74f the flag is set before the reload"
lw_expect_eq "$(cat "$FLAG")" "18/3203210529 -" "R74f flag"
lw_expect_eq "$(lk_lines | wc -l | tr -d ' ')" 1 "R74f one line for the loss"
lk_lines | grep -q 'IPv6 call lost, IPv4 kept' || lw_fail "R74f line for the loss"
lw_expect_eq "$(cat "$EVENTS")" "" "R49i no ifup, no signal for IPv4"
lw_expect_eq "$(lk_calls_of --start-network)$(lk_calls_of --stop-network)" 00 "R49i no start or stop"
[ ! -e "$MARK" ] || lw_fail "R74f the pending marker stays after a reload that worked"

# the loss goes on: the next passes read the status (one call each) and do nothing more
: >"$CALLS"
for _ in 1 2 3; do lw-linkwatch once; done
lw_expect_eq "$(lan6_calls | wc -l | tr -d ' ')" 1 "R74f no second reload for the same loss"
lw_expect_eq "$(lk_lines | wc -l | tr -d ' ')" 1 "R74f no second line for the same loss"
lw_expect_eq "$(lk_calls_of "$V6S")" 0 "R74f no settings call while the loss is flagged"

# the call comes back: the flag goes first, then one reload, one line
echo up >"$T/uqmi/session-18"
lw-linkwatch once
lw_expect_eq "$(lan6_calls | tail -n 1)" "reload lan6 flag=none" "R74f the LAN follows the session again after the flag is gone"
[ ! -e "$FLAG" ] || lw_fail "R74f flag stays after the call came back"
lw_expect_eq "$(lk_lines | wc -l | tr -d ' ')" 2 "R74f one line for the return"

# an unreadable or timed out status changes nothing: not a flag, not a reload, not a line
for answer in @EMPTY @FAIL @HANG garbage '"connected"'; do
    setup
    rm -f "$T/uqmi/q-"*
    # the first data answer is IPv4's (connected), the second IPv6's (scripted); the settings answer is scripted
    printf '"connected"\n%s\n' "$answer" >"$T/uqmi/q-data"
    echo down >"$T/uqmi/session-18"
    lw-linkwatch once
    [ ! -e "$FLAG" ] || lw_fail "R74f flag after the unusable status '$answer'"
    lw_expect_eq "$(lan6_calls)" "" "R74f no reload after the unusable status '$answer'"
    lw_expect_eq "$(lk_lines)" "" "R74f no line after the unusable status '$answer'"
done
# a disconnected status that the settings do not confirm
setup
echo down >"$T/uqmi/session-18"
printf '%s\n' '{"ipv6":{"ip":"2001:db8::2"}}' >"$T/uqmi/q-settings"
lw-linkwatch once
[ ! -e "$FLAG" ] || lw_fail "R74f flag after settings that show a call"
lw_expect_eq "$(lan6_calls)" "" "R74f no reload after settings that show a call"
for answer in @EMPTY @FAIL @HANG garbage; do
    setup
    echo down >"$T/uqmi/session-18"
    printf '%s\n' "$answer" >"$T/uqmi/q-settings"
    lw-linkwatch once
    [ ! -e "$FLAG" ] || lw_fail "R74f flag after the unusable settings '$answer'"
    lw_expect_eq "$(lan6_calls)" "" "R74f no reload after the unusable settings '$answer'"
done

# a reload that fails or hangs: the marker stays, the flag stays, the next pass reloads again and no
# line is written twice
setup
echo down >"$T/uqmi/session-18"
: >"$T/lan6-fail"
lw-linkwatch once
[ -e "$MARK" ] || lw_fail "R74f the marker goes when the reload failed"
rm -f "$T/lan6-fail"
lw-linkwatch once
lw_expect_eq "$(lan6_calls | wc -l | tr -d ' ')" 2 "R74f the failed reload is tried again at the next pass"
[ ! -e "$MARK" ] || lw_fail "R74f the marker stays after the retry worked"
lw_expect_eq "$(lk_lines | wc -l | tr -d ' ')" 1 "R74f the retry writes no second line"
lw_expect_eq "$(cat "$FLAG")" "18/3203210529 -" "R74f flag after the retry"
setup
echo down >"$T/uqmi/session-18"
: >"$T/lan6-hang"
LW_LINKWATCH_UQMI_LIMIT=2 lw-linkwatch once
[ -e "$MARK" ] || lw_fail "R74f the marker goes when the reload hangs"

# a watcher stopped between the flag and the reload: the marker is there, the next pass reloads
setup
mkdir -p /var/run/lw-linkwatch
chmod 700 /var/run/lw-linkwatch
echo "18/3203210529 -" >"$FLAG"
: >"$MARK"
echo down >"$T/uqmi/session-18"
lw-linkwatch once
lw_expect_eq "$(lan6_calls | wc -l | tr -d ' ')" 1 "R74f an interrupted flag is finished by the next pass"
[ ! -e "$MARK" ] || lw_fail "R74f the marker stays after the finished reload"
lw_expect_eq "$(lk_lines)" "" "R74f finishing the reload writes no line of its own"

# a flag of an earlier call or start does not hold: it is removed, and the loss is seen anew
setup
mkdir -p /var/run/lw-linkwatch
chmod 700 /var/run/lw-linkwatch
echo "18/3203210000 -" >"$FLAG"
lw-linkwatch once
[ ! -e "$FLAG" ] || lw_fail "R74f a flag of another handle stays"
LK_IFBIRTH=900 lk_netifd up dual
echo "18/3203210529 700" >"$FLAG"
lw-linkwatch once
[ ! -e "$FLAG" ] || lw_fail "R74f a flag of an earlier start with the same numbers stays"

# the IPv4 call lost together with the IPv6 call: the IPv4 incident is the watcher's work, IPv6 is
# read after IPv4 is back
setup
echo down >"$T/uqmi/session-17"
echo down >"$T/uqmi/session-18"
: >"$CALLS"
lw-linkwatch once
lw_expect_eq "$(lk_calls_of "wds,18")" 0 "R74f no IPv6 read in a pass that finds IPv4 lost"

# R49a, R49h: the session is checked again before every request for the IPv6 call, and the identity
# of both calls before the flag changes. The world changes while a request is answered: the hook of
# the uqmi stand-in rewrites netifd's status after the first request of the kind.
hook() {
    # hook KIND NTH ACTION: after the NTH answered request of KIND, run ACTION (a shell command)
    cat >"$T/on-uqmi" <<HOOK
#!/bin/sh
[ "\$1" = $1 ] || exit 0
n=\$(cat "$T/hook-n" 2>/dev/null || echo 0)
echo \$((n + 1)) >"$T/hook-n"
[ \$((n + 1)) = $2 ] || exit 0
$3
HOOK
    chmod +x "$T/on-uqmi"
    rm -f "$T/hook-n"
}
NETIFD="$T/ifstatus/wwan.json"
DUAL_DOWN='{"up":false,"l3_device":"wwan0","data":{"cid_4":"17","pdh_4":"3203210528","cid_6":"18","pdh_6":"3203210529"}}'
DUAL_19='{"up":true,"l3_device":"wwan0","data":{"cid_4":"17","pdh_4":"3203210528","cid_6":"19","pdh_6":"3203210530"}}'

# wwan goes down while the IPv4 request is answered
setup
echo down >"$T/uqmi/session-18"
hook data 1 "printf '%s\n' '$DUAL_DOWN' >$NETIFD"
: >"$CALLS"
lw-linkwatch once
lw_expect_eq "$(cat "$CALLS")" "$V4D" "R49a wwan down after the IPv4 answer: no request for the IPv6 call"
lw_expect_eq "$(lan6_calls)" "" "R49a wwan down: no reload"
[ ! -e "$FLAG" ] || lw_fail "R49a wwan down: flag"

# The control device disappears before netifd publishes the change.
setup
hook data 1 'rm -f /tmp/cdc-wdm0'
: >"$CALLS"
lw-linkwatch once
lw_expect_eq "$(cat "$CALLS")" "$V4D" "R49a no IPv6 request without the control device"

# a negotiation starts while the IPv4 request is answered
setup
echo down >"$T/uqmi/session-18"
hook data 1 "mkdir -p /var/run/lw-family; echo \$(( \$(cut -d. -f1 $T/uptime) + 30 )) >/var/run/lw-family/negotiating"
: >"$CALLS"
lw-linkwatch once
lw_expect_eq "$(cat "$CALLS")" "$V4D" "R49a negotiation mark after the IPv4 answer: no request for the IPv6 call"
[ ! -e "$FLAG" ] || lw_fail "R49a negotiation: flag"

# the IPv6 client changes (18 to 19, IPv4 identity the same) while its status is answered
setup
echo down >"$T/uqmi/session-18"
hook data 2 "printf '%s\n' '$DUAL_19' >$NETIFD"
: >"$CALLS"
lw-linkwatch once
lw_expect_eq "$(cat "$CALLS")" "$V4D
$V6D" "R49h another IPv6 client after its status: no settings request for the old one"
lw_expect_eq "$(lan6_calls)" "" "R49h another IPv6 client: no reload"
[ ! -e "$FLAG" ] || lw_fail "R49h another IPv6 client: flag"

# the same change while the settings are answered: the flag must not name the new call
setup
echo down >"$T/uqmi/session-18"
hook settings 1 "printf '%s\n' '$DUAL_19' >$NETIFD"
: >"$CALLS"
lw-linkwatch once
lw_expect_eq "$(cat "$CALLS")" "$V4D
$V6D
$V6S" "R49h the settings request was made for the old client"
[ ! -e "$FLAG" ] || lw_fail "R49h the flag of a call that is not the one that was read: $(cat "$FLAG")"
lw_expect_eq "$(lan6_calls)" "" "R49h no reload for another call"

# the call comes back while a flag stands, and the client changes before the flag is cleared
setup
mkdir -p /var/run/lw-linkwatch
chmod 700 /var/run/lw-linkwatch
echo "18/3203210529 -" >"$FLAG"
hook data 2 "printf '%s\n' '$DUAL_19' >$NETIFD"
lw-linkwatch once
lw_expect_eq "$(lan6_calls)" "" "R49h a change of call before the clear: no reload"
[ -e "$FLAG" ] || lw_fail "R49h the flag was cleared on the word of another call"
rm -f "$T/on-uqmi"

# R74f: a reload that did not finish (the init script says so with its exit status) is repeated by
# the watcher without any event of the session: the pending state of the LAN (lan6.sh) or the marker
# of the watcher is enough, whether the session is IPv4-only, IPv6, or gone. The attempts are spaced.
PENDING=$T/pending
for shape in v4 dual v6 down; do
    setup
    LW_LINKWATCH_LAN6_PENDING=$PENDING
    export LW_LINKWATCH_LAN6_PENDING
    if [ "$shape" = down ]; then lk_netifd down dual; else lk_netifd up "$shape"; fi
    : >"$PENDING"
    lw-linkwatch once
    lw_expect_eq "$(lan6_calls)" "reload lan6 flag=none" "R74f pending LAN state, session '$shape': the pass reloads"
    lw_expect_eq "$(lk_lines)" "" "R74f the replay is silent"
    rm -f "$PENDING" "$MARK"
    unset LW_LINKWATCH_LAN6_PENDING
    mkdir -p /var/run/lw-linkwatch
    chmod 700 /var/run/lw-linkwatch
    rm -f "$LAN6CALLS"
    : >"$MARK"
    lw-linkwatch once
    lw_expect_eq "$(lan6_calls)" "reload lan6 flag=none" "R74f marker of the watcher, session '$shape': the pass reloads"
    [ ! -e "$MARK" ] || lw_fail "R74f the marker stays after the reload that worked"
done
setup
LW_LINKWATCH_LAN6_PENDING=$PENDING
export LW_LINKWATCH_LAN6_PENDING
: >"$PENDING"
: >"$T/lan6-fail"
LW_LINKWATCH_PASSES=4 LW_LINKWATCH_PERIOD=1 lw-linkwatch run
lw_expect_eq "$(lan6_calls | wc -l | tr -d ' ')" 1 "R74f a failing replay is not repeated every pass"
LW_LINKWATCH_PASSES=40 LW_LINKWATCH_PERIOD=1 lw-linkwatch run
[ "$(lan6_calls | wc -l | tr -d ' ')" -ge 2 ] || lw_fail "R74f a failing replay is never repeated"
[ "$(lan6_calls | wc -l | tr -d ' ')" -le 4 ] || lw_fail "R74f a failing replay is repeated too often: $(lan6_calls | wc -l)"
rm -f "$PENDING" "$T/lan6-fail"
unset LW_LINKWATCH_LAN6_PENDING

# a session with no IPv6 call: not one call for it, not one more call of any kind, not a state file
for shape in v4 v4half v6; do
    setup
    lk_netifd up $shape
    : >"$CALLS"
    echo down >"$T/uqmi/session-18"
    lw-linkwatch once
    lw_expect_eq "$(lk_calls_of "wds,18")" 0 "R74f session '$shape': no call on the IPv6 client"
    lw_expect_eq "$(lan6_calls)" "" "R74f session '$shape': no reload"
    [ ! -e "$FLAG" ] || lw_fail "R74f session '$shape': flag"
done
setup
lk_netifd up v4
: >"$CALLS"
LW_LINKWATCH_PASSES=5 lw-linkwatch run
lw_expect_eq "$(wc -l <"$CALLS" | tr -d ' ')" 5 "R74f an IPv4-only session: one call per pass, as before"
echo ok
