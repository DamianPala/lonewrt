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
echo ok
