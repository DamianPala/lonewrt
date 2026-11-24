# R73j, R13e: dual stack with static addresses (dhcp 0) and a PIN: the addresses, the prefix and
# the routes of both calls come from the modem, the SIM is unlocked once, the raw-IP driver flag is
# set, and the teardown releases both clients.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

qmi_fixture both-accepted
printf '2468\n' >"$QMI_STATE/pin"
qmi_run setup ipv4v6 '"dhcp":false,"pincode":"2468"' || lw_fail 'static dual-stack setup failed'

lw_expect_eq "$(qmi_notify 0 '.ipaddr[*].ipaddr')" 192.0.2.2 'IPv4 address from QMI'
lw_expect_eq "$(qmi_notify 0 '.ip6addr[*].ipaddr')" 2001:db8::2 'IPv6 address from QMI'
lw_expect_eq "$(qmi_notify 0 '.ip6prefix[*]')" 2001:db8::2/64 'IPv6 prefix from QMI'
# one read of the IPv6 settings, the one that is judged and published, and one of the IPv4 settings
lw_expect_eq "$(qmi_arg_count --get-current-settings)" 2 'settings reads: IPv6 once, IPv4 once'
lw_expect_eq "$(qmi_arg_count --verify-pin1)" 1 'SIM unlocks'
lw_expect_eq "$(cat /sys/class/net/wwan0/qmi/raw_ip)" Y 'raw-IP driver flag'

qmi_run teardown ipv4v6 || lw_fail 'teardown after address updates failed'
lw_expect_eq "$(ls "$QMI_STATE/clients")" '' 'clients after teardown'
echo ok
