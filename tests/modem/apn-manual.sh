# R13: an APN from the profile or LuCI is never touched, however many attempts fail, also when an
# older table marker is left over (R13d). Other interfaces and actions are ignored.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/modem/helpers.inc
. /fw/tests/modem/helpers.inc
modem_setup ''
uci set network.wwan.apn=my.apn
uci set network.wwan.auth=chap
uci commit network

for _ in 1 2 3; do apn_event ifup-failed; done
uci set lonewrt.apn=apn
uci set lonewrt.apn.from_table=tmcg-4g
uci commit lonewrt
for _ in 1 2 3; do apn_event ifup-failed; done
ACTION=ifup-failed INTERFACE=lan sh /etc/hotplug.d/iface/99-auto-apn-at
ACTION=ifdown INTERFACE=wwan sh /etc/hotplug.d/iface/99-auto-apn-at
sleep 1
wait_gone 'usr/lib/lw/lw-apn' 10

lw_expect_eq "$(uci get network.wwan.apn)" my.apn "APN"
lw_expect_eq "$(uci get network.wwan.auth)" chap "auth"
lw_expect_eq "$(count "$T/at-calls" AT+)" 0 "AT commands for a manual APN"
lw_expect_no_grep "$T/events" "ifup"
lw_expect_no_grep "$T/syslog" "Auto-APN"
echo ok
