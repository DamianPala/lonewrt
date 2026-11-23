# R73h: the negotiation has a deadline of 60 s on a clock that does not jump (the uptime file, here
# the stand-in's clock, which only the faults slow and hang move). Calls get at most the time left
# minus the time kept back for the cleanup; at the deadline the start publishes a confirmed call
# or fails once; a cleanup it has no time for is done by the next start's sweep (R73m).
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

# before any call is granted: every start takes 30 s and is refused, so the deadline passes
# during the IPv6 attempt of step 1 and no step goes on
qmi_fixture both-refused
qmi_fault '--start-network' 'slow:30'
qmi_run setup ipv4v6 >/dev/null && lw_fail 'a start past its deadline succeeded'
lw_expect_eq "$(qmi_notify 3 '.error[*]')" CALL_FAILED 'one failed start at the deadline'
lw_expect_eq "$(qmi_arg_count --start-network)" 2 'no call after the deadline'
lw_expect_eq "$(qmi_clock)" 1060 'the clock at the end of the start'
# the client of the second call could not be released: no time was left, the next start's sweep does it
lw_expect_eq "$(ls "$QMI_STATE/clients")" 18 'cleanup that had no time'
rm -f "$QMI_STATE/fault"
cp "$QMI_DIR/scenarios/owner-sim" "$QMI_STATE/scenario"
qmi_run setup ipv4v6 || lw_fail 'the next responsive start failed'
lw_expect_eq "$(ls "$QMI_STATE/clients")" 19 'the next start leaves no client of the earlier one'
qmi_ifdown ipv4v6

# a call that took too long to be confirmed: the call is up at 55 s, its status read has no time left,
# so it is not confirmed, it is stopped by its handle, and the start fails once
qmi_fixture owner-sim
qmi_fault 'wds,17 --start-network' 'slow:55'
qmi_run setup ipv4v6 >/dev/null && lw_fail 'an unconfirmed call was published'
lw_expect_eq "$(qmi_notify 3 '.error[*]')" CALL_FAILED 'one failed start, call not confirmed'
lw_expect_eq "$(qmi_notify 0 '["link-up"]')" '' 'nothing published'
qmi_modem_clean 'after the expiry before a confirmed grant'
lw_expect_eq "$(qmi_arg_count --get-client-id)" 1 'no further attempt'

# after a confirmed grant: IPv4 is granted and confirmed, the modem then stops answering on the IPv6
# client (every call on it takes its limit): IPv4 is published, no failed start
qmi_fixture both-accepted
qmi_fault 'wds,18' hang
qmi_run setup ipv4v6 || lw_fail 'the start with a stalled IPv6 attempt failed'
lw_expect_eq "$(qmi_notify 3 '.error[*]')" '' 'failed starts after a confirmed grant'
lw_expect_eq "$(qmi_notify 0 .data.pdh_4)" -12345678 'IPv4 published by the deadline'
lw_expect_eq "$(qmi_notify 0 .data.pdh_6)" '' 'IPv6 not published'
lw_expect_eq "$(cat "$QMI_STATE/calls/ipv4")" '17 -12345678 1' 'the IPv4 call'
# the stalled client is not released, the modem being silent; the next responsive start finds nothing
lw_expect_eq "$(ls "$QMI_STATE/clients" | tr '\n' ' ')" '17 18 ' 'clients with the modem silent'
qmi_ifdown ipv4v6
rm -f "$QMI_STATE/fault"
qmi_run setup ipv4v6 || lw_fail 'the next responsive start failed'
lw_expect_eq "$(ls "$QMI_STATE/clients" | tr '\n' ' ')" '19 20 ' 'next start: no client of the earlier one'
lw_expect_eq "$(cat "$QMI_STATE/calls/ipv4")" '19 -12345678 1' 'next start: only its own calls'
lw_expect_eq "$(cat "$QMI_STATE/calls/ipv6")" '20 12345679 0' 'next start: IPv6 call, its own'

# a call never gets more than the time left: with 10 s left the 5 s start is cut to 2 s (8 s kept back)
qmi_fixture owner-sim
qmi_fault '--get-profile-settings' 'slow:50' 0 1
qmi_run setup ipv4v6 || lw_fail 'a start with little time left failed'
lw_expect_eq "$(qmi_calls_raw | grep -c -e '-t 2000 --set-client-id wds,17 --start-network')" 1 'start limit cut to the time left'
echo ok
