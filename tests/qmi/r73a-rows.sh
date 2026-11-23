# shellcheck shell=sh disable=SC3043  # BusyBox ash supports local
# R73, R73a: every row of the attempt table through the derived handler, with the options of the
# image's zz-lw-config (device, modes, timeout, pdptype; dhcp and dhcpv6 omitted), once with the
# empty APN of the generic image (R13a) and once with an APN. A row gives the session of its
# families, one published pair per call that was granted, no client left that is not published, and
# a failed start only when every step was refused.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

# check SCENARIO MODE FAMILIES FAILED CLIENTS TYPE: FAMILIES is 4, 6, 46 or - for no session; CLIENTS the
# clients still allocated; TYPE the profile type the modem ends with
check() {
    local label="$1/$2 apn '${QMI_APN}'" rc=0 fam='' n
    qmi_fixture "$1"
    qmi_run setup "$2" >/dev/null || rc=$?
    [ -z "$(qmi_notify 0 .data.pdh_4)" ] || fam=${fam}4
    [ -z "$(qmi_notify 0 .data.pdh_6)" ] || fam=${fam}6
    lw_expect_eq "${fam:--}" "$3" "$label: families of the session"
    lw_expect_eq "$(qmi_notify 3 '.error[*]' | wc -l)" "$4" "$label: failed starts"
    lw_expect_eq "$rc" "$4" "$label: setup status"
    lw_expect_eq "$(ls "$QMI_STATE/clients" | tr '\n' ' ')" "$5" "$label: clients left"
    lw_expect_eq "$(cat "$QMI_STATE/profile.pdp")" "$6" "$label: profile type"
    lw_expect_eq "$(cat "$QMI_STATE/profile.apn")" "$QMI_APN" "$label: profile APN"
    # every call that is up is published and the other way round
    n=${#3}
    [ "$3" != - ] || n=0
    lw_expect_eq "$(ls "$QMI_STATE/calls" | wc -l)" "$n" "$label: calls up"
}

for QMI_APN in '' internet.example; do
    export QMI_APN
    #     scenario            mode    families failed clients  profile type
    check both-accepted       ipv4v6  46       0      '17 18 ' ipv4v6
    check owner-sim           ipv4v6  4        0      '17 '    ipv4v6
    check ipv6-only           ipv4v6  6        0      '18 '    ipv4v6
    check ip-only             ipv4v6  4        0      '19 '    ipv4
    check ipv6-profile-only   ipv4v6  6        0      '20 '    ipv6
    check both-refused        ipv4v6  -        1      ''       ipv4
    # forced: one step
    check owner-sim           ipv4    4        0      '17 '    ipv4
    check ipv6-only           ipv6    6        0      '17 '    ipv6
    check ipv6-only           ipv4    -        1      ''       ipv4
    check owner-sim           ipv6    -        1      ''       ipv4
    # a missing or other value forces IPv4, in any letter case (R73)
    check owner-sim           IP      4        0      '17 '    ipv4
    check owner-sim           ''      4        0      '17 '    ipv4
    check owner-sim           IPV4V6  4        0      '17 '    ipv4v6
    check ipv6-only           Ipv6    6        0      '17 '    ipv6
done
echo ok
