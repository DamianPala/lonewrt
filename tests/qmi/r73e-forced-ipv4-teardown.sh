# R73e, R73m: the teardown of a forced IPv4 session stops the call by the handle that was published
# (signed), before it releases the client, and leaves the modem clean; a second teardown with the
# same published data ends the same way, the stale client being a modem error.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

qmi_fixture owner-sim
qmi_run setup ipv4 || lw_fail 'IPv4 setup failed'
lw_expect_eq "$(cat "$QMI_STATE/calls/ipv4")" '17 -12345678 1' 'active IPv4 call'
cp "$QMI_STATE/status.json" "$QMI_STATE/published.json"

qmi_run teardown ipv4 || lw_fail 'IPv4 teardown failed'
lw_expect_eq "$(qmi_notify 0 '["link-up"]' | tail -n 1)" false 'parent link after teardown'
lw_expect_eq "$(qmi_arg_count -12345678)" 1 'stop request with the published signed handle'
lw_expect_eq "$(qmi_arg_count --release-client-id)" 1 'client releases'
stop=$(qmi_first_line 'stop-network -12345678')
release=$(qmi_first_line 'release-client-id')
[ "$stop" -gt 0 ] && [ "$stop" -lt "$release" ] || lw_fail "stop by handle ($stop) is not before the release ($release)"
qmi_modem_clean 'after teardown'
lw_expect_eq "$(cat "$QMI_STATE/profile.pdp")" ipv4 'profile persists after teardown'

# netifd runs the teardown again with the data it still has: the modem answers with errors
cp "$QMI_STATE/published.json" "$QMI_STATE/status.json"
qmi_run teardown ipv4 || lw_fail 'second teardown failed'
qmi_modem_clean 'after the second teardown'
echo ok
