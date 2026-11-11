# R49b: only the exact answers of the measured failure start an incident. An empty answer, garbage, a
# failing uqmi, one that hangs (the timeout around it ends it) and a call that is not lost (settings
# with an address, the data status of another word) lead to no action: no start, no clear, no signal,
# no ifup, no info line. At the debug level every such answer is logged, at the info level none.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc

# case NAME KIND ANSWER...: the world is lost; the answers of KIND are scripted
try() {
    lk_setup
    lk_lost
    printf '%s\n' "$3" >"$T/uqmi/q-$2"
    # a uqmi call without its timeout would hang on @HANG: a FAIL here, not a stuck test
    rc=0
    timeout 30 lw-linkwatch once || rc=$?
    lw_expect_eq "$rc" 0 "exit code of the pass with $1"
    lk_no_action "$1"
}

try "empty data status" data @EMPTY
try "garbage data status" data 'garbage'
try "failing data status" data @FAIL
try "hanging data status" data @HANG
try "unknown data status" data '"suspended"'
# lost by the data status, but the settings say something else
try "empty settings" settings @EMPTY
try "garbage settings" settings 'Out of call'
try "failing settings" settings @FAIL
try "hanging settings" settings @HANG
try "settings with an address" settings '{"ipv4":{"ip":"10.9.9.9"}}'
try "a different error in the settings" settings '"Call failed"'

# no client in the data of netifd: nothing to ask
lk_setup
lk_lost
printf '{"up":true,"l3_device":"wwan0"}\n' >"$T/ifstatus/wwan.json"
lw-linkwatch once
lk_no_action "without cid_4"
lw_expect_eq "$(lk_calls_of --set-client-id)" 0 "client calls without cid_4"

# the levels: info says nothing, debug names the answer
lk_setup
lk_lost
echo garbage >"$T/uqmi/q-data"
lw-linkwatch once
lw_expect_eq "$(lk_debug_lines)" "" "debug lines at the info level"
uci set lonewrt.log=log
uci set lonewrt.log.level=debug
uci commit lonewrt
lw-linkwatch once
lk_debug_lines | grep -qF "lw-linkwatch: data status: no usable answer 'garbage', no action" ||
    lw_fail "debug line: $(lk_debug_lines)"
lw_expect_eq "$(lk_info)" 1 "log lines of the watcher: only the debug one"
echo ok
