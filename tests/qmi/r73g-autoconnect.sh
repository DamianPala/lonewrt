# R73g: the IPv4 call of every step has autoconnect unless network.wwan.autoconnect is 0, as the
# stock handler does for `ip`; the IPv6 call has it only when the option is 1. The profile,
# v6profile and v6apn options reach their calls (v6apn and v6profile default to apn and profile).
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

# starts MODE EXTRA: the start calls of one start, one per line
starts() {
    qmi_fixture both-accepted
    qmi_run setup "$1" ${2:+"$2"} >/dev/null || lw_fail "setup $1 $2 failed"
    qmi_calls | grep -e '--start-network' | sed 's/^--set-client-id //'
}

lw_expect_eq "$(starts ipv4v6)" 'wds,17 --start-network --apn internet.example --autoconnect
wds,18 --start-network --apn internet.example' 'auto, no autoconnect option'
lw_expect_eq "$(starts ipv4v6 '"autoconnect":0')" 'wds,17 --start-network --apn internet.example
wds,18 --start-network --apn internet.example' 'auto, autoconnect 0'
lw_expect_eq "$(starts ipv4v6 '"autoconnect":1')" 'wds,17 --start-network --apn internet.example --autoconnect
wds,18 --start-network --apn internet.example --autoconnect' 'auto, autoconnect 1'
lw_expect_eq "$(starts ipv4 '"autoconnect":0')" 'wds,17 --start-network --apn internet.example' 'forced IPv4, autoconnect 0'
lw_expect_eq "$(starts ipv4)" 'wds,17 --start-network --apn internet.example --autoconnect' 'forced IPv4'

qmi_fixture ipv6-only
qmi_run setup ipv6 >/dev/null || lw_fail 'forced IPv6 failed'
lw_expect_eq "$(qmi_calls | grep -e '--start-network' | sed 's/^--set-client-id //')" 'wds,17 --start-network --apn internet.example' 'forced IPv6'

# explicit profile, v6profile and v6apn
lw_expect_eq "$(starts ipv4v6 '"profile":2,"v6profile":3,"v6apn":"six.example"')" 'wds,17 --start-network --apn internet.example --profile 2 --autoconnect
wds,18 --start-network --apn six.example --profile 3' 'profile, v6profile and v6apn'
lw_expect_eq "$(starts ipv4v6 '"profile":2')" 'wds,17 --start-network --apn internet.example --profile 2 --autoconnect
wds,18 --start-network --apn internet.example --profile 2' 'v6profile defaults to profile'
echo ok
