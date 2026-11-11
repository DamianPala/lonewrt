# R49a: no uqmi call, no signal, no log line unless netifd shows wwan as up and the control node
# exists, even when the session would count as lost (qmi.sh uses uqmi while it sets the interface up).
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc
lk_setup
lk_lost

lk_netifd down
lw-linkwatch once
lk_expect_quiet "with wwan down in netifd"

rm -f "$T/ifstatus/wwan.json"
lw-linkwatch once
lk_expect_quiet "with no wwan interface in netifd"

lk_netifd up
rm -f /tmp/cdc-wdm0
lw-linkwatch once
lk_expect_quiet "without the control node"

# the same state with everything in place does look: a start is tried
: >/tmp/cdc-wdm0
lw-linkwatch once
[ "$(lk_calls_of --start-network)" -ge 1 ] || lw_fail "no start-network with netifd up and the node there"
echo ok
