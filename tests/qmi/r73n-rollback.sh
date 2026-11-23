# R73n, D203: after a start whose steps all failed, profile 1 gets back the type it had before the
# start only when this start changed it, and the APN the start wrote stays; the type a start came up
# with is kept on flash, written at once and only when it changes; before registration a start
# repairs profile 1 once, and only for a change that the record shows a cut-off start began, with the
# same SIM and APN. A type that differs from the record is no reason alone; a first start or a new
# SIM takes the normal path.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

SIM=8900000000000000001
RECORD=/etc/lw-wwan-ptype

# all steps refused: the type goes back, the new APN stays
qmi_fixture both-refused
qmi_profile old.example ipv4
QMI_APN=new.example qmi_run setup ipv4v6 >/dev/null && lw_fail 'a start with every step refused succeeded'
lw_expect_eq "$(cat "$QMI_STATE/profile.pdp")" ipv4 'profile type after the failed start'
lw_expect_eq "$(cat "$QMI_STATE/profile.apn")" new.example 'the APN of the start stays'
lw_expect_eq "$(qmi_calls | grep -e '--modify-profile' | tail -n 1)" '--modify-profile 3gpp,1 --apn new.example --pdp-type ipv4' 'the rollback write'

# the same with a type this start did not change: no rollback write
qmi_fixture both-refused
qmi_profile internet.example ipv4
qmi_run setup ipv4 >/dev/null && lw_fail 'forced IPv4 with a refusal succeeded'
lw_expect_eq "$(qmi_count '--modify-profile')" 0 'a type the start did not change is not written back'
lw_expect_eq "$(cat "$QMI_STATE/profile.pdp")" ipv4 'profile type'

# a start that came up records its type at once, and only when it changes
qmi_fixture owner-sim
qmi_run setup ipv4v6 || lw_fail 'auto start failed'
lw_expect_eq "$(cat $RECORD)" "ok ipv4v6 internet.example $SIM" 'record of the type the start came up with'
lw_expect_eq "$(find /etc -maxdepth 1 -name 'lw-wwan-ptype.*' | wc -l)" 0 'no temporary file of the write'
qmi_ifdown ipv4v6
before=$(qmi_count '--get-iccid')
qmi_run setup ipv4v6 || lw_fail 'second auto start failed'
lw_expect_eq "$(qmi_count '--get-iccid')" "$before" 'an unchanged record is not written again'
lw_expect_eq "$(cat $RECORD)" "ok ipv4v6 internet.example $SIM" 'record unchanged'
qmi_ifdown ipv4v6
# forced IPv4 later: the type changes, so does the record, with the change recorded first
QMI_APN=internet.example qmi_run setup ipv4 || lw_fail 'forced IPv4 start failed'
lw_expect_eq "$(cat $RECORD)" "ok ipv4 internet.example $SIM" 'record after the change of the type'

# a start that fails after it began a change keeps the record of the change; the same SIM and APN
# then repair profile 1 once before registration, not at every start after it is back
qmi_fixture both-refused
qmi_profile internet.example ipv4
qmi_run setup ipv4v6 >/dev/null && lw_fail 'a failing start succeeded'
lw_expect_eq "$(cat $RECORD)" "change ipv4 internet.example $SIM" 'the change a start began is recorded'

# the repair: a start cut off after it changed the type (profile at IPV6, record of the change)
repair() {
    qmi_fixture owner-sim
    qmi_profile "${2:-internet.example}" ipv6
    printf '%s\n' "$1" >$RECORD
    [ -z "${3:-}" ] || printf '%s\n' "$3" >"$QMI_STATE/iccid"
    QMI_APN=internet.example qmi_run setup ipv4 || lw_fail 'the start after the cut-off failed'
}

repair "change ipv4 internet.example $SIM"
reg=$(qmi_first_line '--network-register')
fix=$(qmi_first_line '--modify-profile 3gpp,1 --apn internet.example --pdp-type ipv4')
[ "$fix" -gt 0 ] && [ "$fix" -lt "$reg" ] || lw_fail "the repair ($fix) is not before the registration ($reg)"
lw_expect_eq "$(qmi_count '--modify-profile')" 1 'one write: the repair, the start finds the type right'
lw_expect_eq "$(cat "$QMI_STATE/profile.pdp")" ipv4 'profile after the repair'

repair "change ipv4 internet.example $SIM" internet.example 8900000000000000002
reg=$(qmi_first_line '--network-register')
first=$(qmi_first_line '--modify-profile')
[ "$first" -gt "$reg" ] || lw_fail "a new SIM got a repair ($first before $reg)"

repair "change ipv4 other.example $SIM"
first=$(qmi_first_line '--modify-profile')
[ "$first" -gt "$(qmi_first_line '--network-register')" ] || lw_fail 'another APN got a repair'

# a type that differs from the record is no reason alone
repair "ok ipv4 internet.example $SIM"
first=$(qmi_first_line '--modify-profile')
[ "$first" -gt "$(qmi_first_line '--network-register')" ] || lw_fail 'a record of a good start got a repair'

# a first start has no record: the normal path
qmi_fixture owner-sim
qmi_profile internet.example ipv6
QMI_APN=internet.example qmi_run setup ipv4 || lw_fail 'a first start failed'
first=$(qmi_first_line '--modify-profile')
[ "$first" -gt "$(qmi_first_line '--network-register')" ] || lw_fail 'a first start got a repair'

# a start killed after it changed the type: the record names the change, the next start repairs it
qmi_fixture both-refused
qmi_profile internet.example ipv4
qmi_fault '--modify-profile' kill 1
qmi_run setup ipv4v6 >/dev/null && lw_fail 'the killed start returned'
lw_expect_eq "$(cat "$QMI_STATE/profile.pdp")" ipv4v6 'the cut-off start left the type of its step'
lw_expect_eq "$(cat $RECORD)" "change ipv4 internet.example $SIM" 'the record of the cut-off change'
rm -f "$QMI_STATE/fault"
cp "$QMI_DIR/scenarios/owner-sim" "$QMI_STATE/scenario"
: >"$QMI_STATE/uqmi.jsonl"
QMI_APN=internet.example qmi_run setup ipv4 || lw_fail 'the start after the cut-off failed'
lw_expect_eq "$(qmi_first_line '--modify-profile')" "$(qmi_first_line '--modify-profile 3gpp,1 --apn internet.example --pdp-type ipv4$')" 'the repair'
[ "$(qmi_first_line '--modify-profile')" -lt "$(qmi_first_line '--network-register')" ] || lw_fail 'no repair before the registration'
echo ok
