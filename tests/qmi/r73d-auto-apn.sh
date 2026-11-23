# R73d, R13b, R13d: the real failure consumer (the hotplug script and the Auto-APN worker of the
# image) fed by the handler's real failed starts. A network that grants calls only with the APN of
# the operator table refuses every call of the empty APN: each of the first two starts fails once
# (one error, so one ifup-failed that the test delivers as netifd would), the second makes the
# worker write the table APN and reconnect once, and the third start comes up with it, in auto and
# with both families granted. A start that only has IPv6 refused gives no failed start at all.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/modem/helpers.inc
. /fw/tests/modem/helpers.inc
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

modem_setup ''
rm -f /etc/config/lonewrt
qmi_fixture both-accepted
qmi_profile '' ipv4
printf 'tmcg-4g\n' >"$QMI_STATE/need-apn"

# start: one start of the handler with the APN of network.wwan, as netifd passes it
start() {
    QMI_APN=$(uci -q get network.wwan.apn || :) qmi_run setup ipv4v6 >/dev/null
}

start && lw_fail 'the first start with the empty APN succeeded'
apn_event ifup-failed
lw_expect_eq "$(uci -q get network.wwan.apn || :)" '' 'APN after the first failed start'
start && lw_fail 'the second start with the empty APN succeeded'
apn_event ifup-failed
lw_expect_eq "$(qmi_notify 3 '.error[*]' | tr '\n' ' ')" 'CALL_FAILED CALL_FAILED ' 'one failed start per start'
lw_expect_eq "$(uci get network.wwan.apn)" tmcg-4g 'APN from the table after two failed starts'
lw_expect_eq "$(grep -c '^ifup wwan' "$T/events")" 1 'one reconnect'
qmi_modem_clean 'after the failed starts'

start || lw_fail 'the third start with the table APN failed'
apn_event ifup
lw_expect_eq "$(qmi_notify 3 '.error[*]' | wc -l)" 2 'no failed start after the APN switch'
lw_expect_eq "$(qmi_notify 0 .data.pdh_4)" -12345678 'IPv4 of the third start'
lw_expect_eq "$(qmi_notify 0 .data.pdh_6)" 12345679 'IPv6 of the third start'
lw_expect_eq "$(cat "$QMI_STATE/profile.apn")" tmcg-4g 'profile 1 holds the table APN'
lw_expect_eq "$(grep -c '^ifup wwan' "$T/events")" 1 'still one reconnect'
lw_expect_grep "$T/syslog" "connected with APN 'tmcg-4g' from the operator table"

# a SIM that grants IPv4 and refuses IPv6 gives no failed start, so the worker never counts one
qmi_fixture owner-sim
qmi_profile '' ipv4
rm -f "$QMI_STATE/need-apn"
uci delete network.wwan.apn
uci commit network
uci delete lonewrt.apn.from_table
uci commit lonewrt
: >"$T/events"
for _ in 1 2 3; do
    start && apn_event ifup
    qmi_ifdown ipv4v6
done
lw_expect_eq "$(qmi_notify 3 '.error[*]' | wc -l)" 0 'failed starts on the IPv4-only SIM'
lw_expect_eq "$(grep -c '^ifup wwan' "$T/events")" 0 'no reconnect on the IPv4-only SIM'
lw_expect_eq "$(uci -q get network.wwan.apn || :)" '' 'APN of the IPv4-only SIM'
echo ok
