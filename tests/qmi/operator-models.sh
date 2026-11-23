# shellcheck shell=sh disable=SC3043  # BusyBox ash supports local
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

# Exercise the scenario matrix directly: stock setup would stop before reaching IPv6.
modem() { uqmi -s -d /dev/cdc-wdm0 -t 1000 "$@"; }

expect_start() {
    local cid result rc=0
    modem --modify-profile 3gpp,1 --apn internet.example --pdp-type "$1"
    cid=$(modem --get-client-id wds)
    modem --set-client-id "wds,$cid" --set-ip-family "$2"
    result=$(modem --set-client-id "wds,$cid" --start-network --apn internet.example) || rc=$?
    lw_expect_eq "$result" "$3" "$1/$2 start reply"
    lw_expect_eq "$rc" "$4" "$1/$2 exit status"
    modem --set-client-id "wds,$cid" --release-client-id wds
}

qmi_fixture ipv6-only
expect_start ipv4v6 ipv4 '"Call failed"' 1
expect_start ipv4v6 ipv6 12345679 0
lw_expect_eq "$(ls "$QMI_STATE/calls")" ipv6 'calls after releasing the live IPv6 client'

qmi_fixture both-refused
expect_start ipv4v6 ipv4 '"Call failed"' 1
expect_start ipv4v6 ipv6 '"Call failed"' 1
lw_expect_eq "$(ls "$QMI_STATE/calls")" '' 'calls after both refusals'

qmi_fixture ip-only
expect_start ipv4v6 ipv4 '"Call failed"' 1
expect_start ipv4v6 ipv6 '"Call failed"' 1
expect_start ipv4 ipv4 -12345678 0
lw_expect_eq "$(ls "$QMI_STATE/calls")" ipv4 'calls after switching to IP'
lw_expect_eq "$(ls "$QMI_STATE/clients")" '' 'clients after the releases'
echo ok
