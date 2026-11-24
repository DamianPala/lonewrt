# R73e, E2 item 3: no wildcard stop while a sibling call may exist. The stand-in can make the
# modem's client-local wildcard reach the other client's call too (wide-wildcard, unmeasured on the
# MF289F); a start that cleans up a failed IPv6 call beside a working IPv4 call must then still leave
# the IPv4 call up, because it stops only by the handle it holds, before it releases the client.
# The teardown, which ends both calls, keeps the stock wildcard on each client first.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

qmi_fixture both-accepted
: >"$QMI_STATE/wide-wildcard"
qmi_fault 'wds,18 --set-ip-family ipv6 --get-data-status' 'reply:"disconnected"'
qmi_run setup ipv4v6 || lw_fail 'the start failed'
lw_expect_eq "$(cat "$QMI_STATE/calls/ipv4")" '17 -12345678 1' 'the IPv4 call survived the cleanup of the IPv6 call'
lw_expect_eq "$(ls "$QMI_STATE/calls")" ipv4 'calls'
lw_expect_eq "$(qmi_calls | grep -c -e 'wds,[0-9]* --stop-network 0xffffffff' || :)" 0 'no wildcard stop on a client during the start'
lw_expect_eq "$(qmi_calls | grep -e '--stop-network')" '--stop-network 0xffffffff --autoconnect
--set-ip-family ipv6 --stop-network 0xffffffff --autoconnect
--set-client-id wds,18 --stop-network 12345679' 'stops: the sweep before the calls, then the handle'

# with the wide wildcard the stock teardown ends both calls
qmi_ifdown ipv4v6
qmi_modem_clean 'after the teardown'
# A lost start answer and a failed status read leave the client for the next sweep.
qmi_fixture both-accepted
qmi_fault 'wds,18 --start-network' lose
qmi_fault 'wds,18 --get-data-status' hang
qmi_fault 'wds,18 --set-ip-family ipv6 --get-data-status' block
qmi_run setup ipv4v6 || lw_fail 'the IPv4 sibling was lost'
[ -f "$QMI_STATE/clients/18" ] || lw_fail 'unknown IPv6 call lost its client beside IPv4'
lw_expect_eq "$(qmi_calls | grep -c -e 'wds,18 --set-ip-family ipv6 --get-data-status')" 1 \
    'reconciliation queries the IPv6 family'

# Without a sibling, keep releasing the client when the status cannot be read.
qmi_fixture ipv6-only
qmi_fault 'wds,17 --start-network' lose
qmi_fault 'wds,17 --get-data-status' hang
qmi_fault 'wds,17 --set-ip-family ipv6 --get-data-status' hang
if qmi_run setup ipv6; then lw_fail 'published an IPv6 call without a handle'; fi
[ ! -e "$QMI_STATE/clients/17" ] || lw_fail 'unknown IPv6 client was kept without a sibling'
echo ok
