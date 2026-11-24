# R73e: the faults of a call, one at a time, on the IPv6 call of a SIM that grants both (so the IPv4
# call works and has to stay up) and on the IPv4 call: a text or empty reply, a failed family
# selection, a handle followed by a bad status, a hung call, an answer that never came. Only
# connected calls are published, every client taken is released once or published, a call that
# failed after it started is stopped by its handle before its client is released, and no start
# fails while a call is up.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

# run_fault LABEL MATCH ACTION: a fresh modem, the fault, one auto start; the IPv4 call is up
run_fault() {
    label=$1
    qmi_fixture both-accepted
    qmi_fault "$2" "$3"
    qmi_run setup ipv4v6 || lw_fail "$label: the start failed"
    lw_expect_eq "$(qmi_notify 3 '.error[*]')" '' "$label: failed starts"
    lw_expect_eq "$(qmi_notify 0 .data.pdh_4)" -12345678 "$label: IPv4 published"
    lw_expect_eq "$(qmi_notify 0 .data.pdh_6)" '' "$label: IPv6 not published"
    lw_expect_eq "$(cat "$QMI_STATE/calls/ipv4")" '17 -12345678 1' "$label: IPv4 call stays up"
    lw_expect_eq "$(qmi_json_lines "$DYNAMIC" '@[*].name')" wwan_4 "$label: children"
    lw_expect_eq "$(qmi_calls_from 'wds,17 --start-network' | grep -c -e 0xffffffff -e --sync || :)" 0 \
        "$label: no global operation after a call is up"
}

run_fault 'text reply' 'wds,18 --start-network' 'reply:Out of range'
lw_expect_eq "$(ls "$QMI_STATE/clients")" 17 'text reply: IPv6 client released'
lw_expect_eq "$(ls "$QMI_STATE/calls")" ipv4 'text reply: calls'

run_fault 'empty reply, call not up' 'wds,18 --start-network' 'reply:'
lw_expect_eq "$(ls "$QMI_STATE/clients")" 17 'empty reply: IPv6 client released after a status read'
lw_expect_eq "$(qmi_count 'wds,18 --set-ip-family ipv6 --get-data-status')" 1 'empty reply: reconciled on its client'

run_fault 'timeout text, call not up' 'wds,18 --start-network' 'reply:"Request timed out"'
lw_expect_eq "$(ls "$QMI_STATE/clients")" 17 'timeout text: IPv6 client released after a status read'
lw_expect_eq "$(qmi_count 'wds,18 --set-ip-family ipv6 --get-data-status')" 1 'timeout text: reconciled on its client'

run_fault 'failed family selection' 'wds,18 --set-ip-family' 'error:Invalid value'
lw_expect_eq "$(ls "$QMI_STATE/clients")" 17 'family: IPv6 client released'
lw_expect_eq "$(qmi_arg_count --start-network)" 1 'family: no call without a family'

run_fault 'bad status after a handle' 'wds,18 --set-ip-family ipv6 --get-data-status' 'reply:"disconnected"'
lw_expect_eq "$(ls "$QMI_STATE/clients")" 17 'status: IPv6 client released'
lw_expect_eq "$(ls "$QMI_STATE/calls")" ipv4 'status: the started IPv6 call was stopped'
stop=$(qmi_first_line 'wds,18 --stop-network 12345679')
release=$(qmi_first_line 'wds,18 --release-client-id')
[ "$stop" -gt 0 ] && [ "$stop" -lt "$release" ] || lw_fail "status: stop by handle ($stop) not before the release ($release)"

run_fault 'hung start' 'wds,18 --start-network' hang
lw_expect_eq "$(ls "$QMI_STATE/clients")" 17 'hang: IPv6 client released'
lw_expect_eq "$(qmi_clock)" 1005 'hang: the clock moved by the call limit only'

run_fault 'hung status, killed by the limit' 'wds,18 --set-ip-family ipv6 --get-data-status' block
lw_expect_eq "$(ls "$QMI_STATE/clients")" 17 'block: IPv6 client released'
lw_expect_eq "$(ls "$QMI_STATE/calls")" ipv4 'block: the IPv6 call was stopped by its handle'

# the answer to the IPv6 start never came but the call is up, beside a working one: no wildcard stop
# beside a sibling, the client is left for the next start's sweep (R73e, R73m)
run_fault 'lost answer beside a sibling' 'wds,18 --start-network' lose
# shellcheck disable=SC2012 # fixture filenames are numeric client IDs
lw_expect_eq "$(ls "$QMI_STATE/clients" | tr '\n' ' ')" '17 18 ' 'lost answer: the client of the unknown call stays'
lw_expect_eq "$(qmi_count 'wds,18 --stop-network')" 0 'lost answer: nothing stops a call of unknown handle beside a sibling'
qmi_ifdown ipv4v6
qmi_run setup ipv4v6 >/dev/null || lw_fail 'the next start failed'
# shellcheck disable=SC2012 # fixture filenames are numeric client IDs
lw_expect_eq "$(ls "$QMI_STATE/clients" | tr '\n' ' ')" '19 20 ' 'next start: no client of the earlier one'
lw_expect_eq "$(cat "$QMI_STATE/calls/ipv6")" '20 12345679 0' 'next start: the IPv6 call is its own'

# the same on the IPv4 call: nothing else is up, so the call is stopped on its own client and the
# session is IPv6 alone (step 1 goes on)
qmi_fixture both-accepted
qmi_fault 'wds,17 --start-network' lose
qmi_run setup ipv4v6 || lw_fail 'lost IPv4 answer: the start failed'
lw_expect_eq "$(qmi_notify 3 '.error[*]')" '' 'lost IPv4 answer: failed starts'
lw_expect_eq "$(qmi_notify 0 .data.pdh_4)" '' 'lost IPv4 answer: IPv4 not published'
lw_expect_eq "$(qmi_notify 0 .data.pdh_6)" 12345679 'lost IPv4 answer: IPv6 published'
lw_expect_eq "$(ls "$QMI_STATE/calls")" ipv6 'lost IPv4 answer: the unknown call was stopped'
lw_expect_eq "$(ls "$QMI_STATE/clients")" 18 'lost IPv4 answer: clients'
echo ok
