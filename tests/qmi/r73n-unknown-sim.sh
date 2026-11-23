# R73n, D203: a modem that offers no SIM identity (the MF289F answers --get-iccid and --get-imsi with
# "Not supported") never gets the pre-registration repair: an unknown SIM matches nothing, not even
# another unknown one. The failed identity read is bounded and never logged at the info level. A
# forced IPv4 start on such a SIM adds to the stock calls only the profile read and, once, the SIM
# read, each with -t 1000.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

RECORD=/etc/lw-wwan-ptype

# the record names a change of the type, the SIM is unknown in the record and now: no repair
qmi_fixture owner-sim
qmi_fault '--get-iccid' 'error:Not supported'
qmi_profile internet.example ipv6
printf '%s\n' 'change ipv4 internet.example -' >$RECORD
QMI_APN=internet.example qmi_run setup ipv4 || lw_fail 'the start on a SIM of unknown identity failed'
first=$(qmi_first_line '--modify-profile')
[ "$first" -gt "$(qmi_first_line '--network-register')" ] || lw_fail "an unknown SIM got a repair ($first)"
lw_expect_eq "$(qmi_calls_raw | grep -c -e '-t 1000 --get-iccid')" 3 'identity reads: repair check, record of the change, record of the result'
lw_expect_eq "$(qmi_syslog)" '' 'lines at the info level'

# the record has a SIM, the modem now gives none: no repair either
qmi_fixture owner-sim
qmi_fault '--get-iccid' 'error:Not supported'
qmi_profile internet.example ipv6
printf '%s\n' "change ipv4 internet.example 8900000000000000001" >$RECORD
QMI_APN=internet.example qmi_run setup ipv4 || lw_fail 'the start without an identity failed'
first=$(qmi_first_line '--modify-profile')
[ "$first" -gt "$(qmi_first_line '--network-register')" ] || lw_fail "a start without an identity got a repair"

# the record has no SIM, the modem gives one now: no repair
qmi_fixture owner-sim
qmi_profile internet.example ipv6
printf '%s\n' 'change ipv4 internet.example -' >$RECORD
QMI_APN=internet.example qmi_run setup ipv4 || lw_fail 'the start with a new identity failed'
first=$(qmi_first_line '--modify-profile')
[ "$first" -gt "$(qmi_first_line '--network-register')" ] || lw_fail 'a record without a SIM got a repair'

# today's owner SIM: forced IPv4, the profile already right, no record yet. Beside the stock calls the
# start makes the profile read and, to write the record, one identity read, both with -t 1000
qmi_fixture owner-sim
qmi_fault '--get-iccid' 'error:Not supported'
qmi_profile internet.example ipv4
rm -f $RECORD
out=$(QMI_APN=internet.example qmi_run setup ipv4) || lw_fail 'the forced IPv4 start failed'
lw_expect_eq "$out" 'Waiting for SIM initialization
PIN verification is disabled
Device does not support 802.3 mode. Informing driver of raw-ip only for wwan0 ..
Waiting for network registration
Starting network wwan
Setting up wwan0' 'log of the forced IPv4 start'
lw_expect_eq "$(qmi_calls_raw | grep -e '--get-profile-settings' -e '--get-iccid' -e '--modify-profile')" \
    '-s -d /dev/cdc-wdm0 -t 1000 --get-profile-settings 3gpp,1
-s -d /dev/cdc-wdm0 -t 1000 --get-iccid' 'calls added to the stock ones, first start'
lw_expect_eq "$(cat $RECORD)" 'ok ipv4 internet.example -' 'the record of an unknown SIM'
lw_expect_eq "$(qmi_syslog)" '' 'lines at the info level'
qmi_ifdown ipv4

# the second start: the record is unchanged, so only the profile read is added
: >"$QMI_STATE/uqmi.jsonl"
QMI_APN=internet.example qmi_run setup ipv4 >/dev/null || lw_fail 'the second forced IPv4 start failed'
lw_expect_eq "$(qmi_calls_raw | grep -e '--get-profile-settings' -e '--get-iccid' -e '--modify-profile')" \
    '-s -d /dev/cdc-wdm0 -t 1000 --get-profile-settings 3gpp,1' 'calls added to the stock ones, next start'
echo ok
