# R49f: a healthy pass makes one uqmi call (the data status) and writes nothing: no syslog line, at
# any log level, and no file on flash or in RAM. R49a, R49b: the call has -t and the shape of
# qmi.sh's own status query, on netifd's IPv4 client.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc
lk_setup

for level in info debug; do
    uci set lonewrt.log=log
    uci set lonewrt.log.level=$level
    uci commit lonewrt
    : >"$LW_TEST/marker"
    /bin/sleep 1
    : >"$CALLS"
    lw-linkwatch once
    lw_expect_eq "$(cat "$CALLS")" "-s -d /tmp/cdc-wdm0 -t 3000 --set-client-id wds,17 --get-data-status" \
        "calls of a healthy pass ($level)"
    lw_expect_eq "$(cat "$EVENTS")" "" "events ($level)"
    lw_expect_eq "$(cat "$LKS")" "" "syslog of a healthy pass ($level)"
    [ ! -e "$LW_TEST/syslog.prio" ] || lw_expect_eq "$(cat "$LW_TEST/syslog.prio")" "" "priorities ($level)"
    written=$(find /tmp /etc /root /var -newer "$LW_TEST/marker" -type f 2>/dev/null | grep -v '^/tmp/fake' || true)
    lw_expect_eq "$written" "" "files written by a healthy pass ($level)"
    [ ! -e /tmp/lw-linkwatch ] || lw_fail "state directory created by a healthy pass ($level)"
done
echo ok
