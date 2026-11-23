# R73m: after the interface went down, after a killed start, after a second teardown and after the
# loss of the router's RAM with the modem keeping its state, the next start leaves no client of an
# earlier start allocated and no call of it in the modem. The sweep and the client release before
# the calls are the stock handler's; the start never repeats them while a call of its own is up.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

# a start killed between taking the IPv6 client and publishing: IPv4 is up, the IPv6 call too,
# nothing published (netifd's teardown finds no data)
qmi_fixture both-accepted
qmi_fault 'wds,18 --set-ip-family ipv6 --get-data-status' kill
qmi_run setup ipv4v6 >/dev/null && lw_fail 'the killed start returned'
lw_expect_eq "$(qmi_notify 0 '["link-up"]')" '' 'nothing published by the killed start'
lw_expect_eq "$(ls "$QMI_STATE/calls" | tr '\n' ' ')" 'ipv4 ipv6 ' 'the killed start left its calls'
qmi_ifdown ipv4v6
lw_expect_eq "$(ls "$QMI_STATE/calls" | tr '\n' ' ')" 'ipv4 ipv6 ' 'the teardown reads only published handles'
rm -f "$QMI_STATE/fault"
qmi_run setup ipv4v6 || lw_fail 'the start after the kill failed'
lw_expect_eq "$(ls "$QMI_STATE/clients" | tr '\n' ' ')" '19 20 ' 'clients of the start after the kill'
lw_expect_eq "$(cat "$QMI_STATE/calls/ipv4")" '19 -12345678 1' 'IPv4 call is its own'
lw_expect_eq "$(cat "$QMI_STATE/calls/ipv6")" '20 12345679 0' 'IPv6 call is its own'
lw_expect_eq "$(qmi_notify 3 '.error[*]')" '' 'failed starts'

# the interface goes down during a start (netifd kills the setup): the same
qmi_fixture owner-sim
qmi_fault 'wds,17 --get-data-status' kill
qmi_run setup ipv4v6 >/dev/null && lw_fail 'the killed start returned'
rm -f "$QMI_STATE/fault"
qmi_ifdown ipv4v6
qmi_run setup ipv4v6 || lw_fail 'the start after the ifdown failed'
lw_expect_eq "$(ls "$QMI_STATE/clients")" 18 'clients of the start after the ifdown'
lw_expect_eq "$(cat "$QMI_STATE/calls/ipv4")" '18 -12345678 1' 'the call is its own'

# a second teardown with the same data: the modem's errors for the released clients end nothing
qmi_fixture both-accepted
qmi_run setup ipv4v6 || lw_fail 'setup failed'
cp "$QMI_STATE/status.json" "$QMI_STATE/published.json"
qmi_ifdown ipv4v6
cp "$QMI_STATE/published.json" "$QMI_STATE/status.json"
qmi_ifdown ipv4v6
qmi_modem_clean 'after two teardowns'
qmi_ifdown ipv4v6
qmi_run setup ipv4v6 || lw_fail 'setup after two teardowns failed'
lw_expect_eq "$(qmi_notify 3 '.error[*]')" '' 'failed starts after two teardowns'

# RAM lost with the modem's state kept: netifd's data is gone, the calls and clients are not, and
# the flash record of the profile type stays; the next start owns what it finds
qmi_fixture both-accepted
qmi_run setup ipv4v6 || lw_fail 'setup failed'
printf '{"up":false,"data":{}}\n' >"$QMI_STATE/status.json"
rm -f "$QMI_STATE/registered" "$QMI_STATE/modes"
record=$(cat /etc/lw-wwan-ptype)
lw_expect_eq "$(ls "$QMI_STATE/clients" | tr '\n' ' ')" '17 18 ' 'clients that outlive the RAM'
qmi_run setup ipv4v6 || lw_fail 'the start after the RAM loss failed'
lw_expect_eq "$(ls "$QMI_STATE/clients" | tr '\n' ' ')" '19 20 ' 'clients after the RAM loss'
lw_expect_eq "$(cat "$QMI_STATE/calls/ipv4")" '19 -12345678 1' 'IPv4 call after the RAM loss'
lw_expect_eq "$(cat "$QMI_STATE/calls/ipv6")" '20 12345679 0' 'IPv6 call after the RAM loss'
lw_expect_eq "$(cat /etc/lw-wwan-ptype)" "$record" 'the flash record'
echo ok
