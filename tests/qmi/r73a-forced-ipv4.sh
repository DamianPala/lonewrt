# R73, R73a, R73g, R73b: forced IPv4 (`ipv4`, the image's default) is one step and makes the calls
# the stock handler makes, with the same arguments and the same log, and it is what auto does on a
# SIM that grants only IPv4. The profile is seeded at IPV4V6 so that the write of the stock handler
# is visible; the reads of the profile and of the SIM that the negotiation adds are left out.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

# the lines of the stock handler for a start with a registered, PIN-free SIM
want_log='Waiting for SIM initialization
PIN verification is disabled
Device does not support 802.3 mode. Informing driver of raw-ip only for wwan0 ..
Waiting for network registration
Starting network wwan
Setting up wwan0'

qmi_fixture owner-sim
qmi_profile internet.example ipv4v6
out=$(qmi_run setup ipv4) || lw_fail 'IPv4 setup failed'
lw_expect_eq "$out" "$want_log" 'log of forced IPv4'

want='--get-pin-status
--get-pin-status
--uim-get-sim-state
--uim-get-sim-state
--get-pin-status
--stop-network 0xffffffff --autoconnect
--set-ip-family ipv6 --stop-network 0xffffffff --autoconnect
--set-device-operating-mode online
--set-data-format 802.3
--wda-set-data-format 802.3
--wda-get-data-format
--sync
--network-register
--set-network-modes lte
--get-serving-system
--modify-profile 3gpp,1 --apn internet.example --pdp-type ipv4
--get-client-id wds
--set-client-id wds,17 --set-ip-family ipv4
--set-client-id wds,17 --start-network --apn internet.example --autoconnect
--set-client-id wds,17 --get-data-status'
have=$(qmi_calls | grep -v -e --get-profile-settings -e --get-iccid)
lw_expect_eq "$have" "$want" 'calls of forced IPv4 (the stock calls)'
# the timeouts of the stock calls: 1000 ms, the start 5000 ms
lw_expect_eq "$(qmi_calls_raw | grep -c -e '-t 5000 --set-client-id wds,17 --start-network')" 1 'start timeout'

lw_expect_eq "$(qmi_notify 0 '["link-up"]')" true 'parent link'
lw_expect_eq "$(qmi_notify 0 .ifname)" wwan0 'parent device'
lw_expect_eq "$(qmi_notify 0 .data.cid_4)" 17 'IPv4 CID'
lw_expect_eq "$(qmi_notify 0 .data.pdh_4)" -12345678 'signed IPv4 PDH'
lw_expect_eq "$(qmi_notify 0 .data.cid_6)" '' 'IPv6 CID'
lw_expect_eq "$(qmi_notify 3 '.error[*]')" '' 'setup errors'
lw_expect_eq "$(qmi_child wwan_4 proto)" dhcp 'IPv4 child protocol'
lw_expect_eq "$(qmi_child wwan_4 ifname)" @wwan 'IPv4 child parent'
lw_expect_eq "$(qmi_json_lines "$DYNAMIC" '@[*].name')" wwan_4 'children'
lw_expect_eq "$(cat "$QMI_STATE/profile.pdp")" ipv4 'stored PDP type'
lw_expect_eq "$(cat "$QMI_STATE/profile.apn")" internet.example 'stored APN'
lw_expect_eq "$(ls "$QMI_STATE/clients")" 17 'live clients'
lw_expect_eq "$(cat "$QMI_STATE/clients/17")" ipv4 'selected family'
lw_expect_eq "$(ls "$QMI_STATE/calls")" ipv4 'active families'
lw_expect_eq "$(cat "$QMI_STATE/calls/ipv4")" '17 -12345678 1' 'IPv4 call with autoconnect'
lw_expect_eq "$(qmi_syslog)" '' 'debug lines at the info level'

# the owner's SIM in auto: the same log and the same session, one refused IPv6 call (R73b)
qmi_fixture owner-sim
auto_out=$(qmi_run setup ipv4v6) || lw_fail 'auto setup failed'
lw_expect_eq "$auto_out" "$out" 'info log of auto on an IPv4-only SIM equals the one of forced IPv4'
echo ok
