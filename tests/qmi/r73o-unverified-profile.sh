# R73o: when the modem does not let the start read profile 1, the start writes and starts as the
# stock handler does, and the debug log has one line for the unverified write; a write that fails or
# does not stick is logged the same way and the call that follows it is not counted as refused. No
# log line holds the raw profile.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

# an unreadable profile, forced IPv4: the stock write and the stock calls
qmi_fixture owner-sim
qmi_profile internet.example ipv4v6
qmi_fault '--get-profile-settings' 'error:Not supported'
qmi_debug
qmi_run setup ipv4 || lw_fail 'forced IPv4 with an unreadable profile failed'
lw_expect_eq "$(qmi_calls | grep -v -e --get-profile-settings -e --get-iccid | sed -n '/--modify-profile/,$p')" \
    '--modify-profile 3gpp,1 --apn internet.example --pdp-type ipv4
--get-client-id wds
--set-client-id wds,17 --set-ip-family ipv4
--set-client-id wds,17 --start-network --apn internet.example --autoconnect
--set-client-id wds,17 --get-data-status' 'the stock calls'
lw_expect_eq "$(qmi_count '--get-profile-settings')" 1 'no read after the write of an unreadable profile'
lw_expect_eq "$(qmi_notify 0 .data.pdh_4)" -12345678 'IPv4 published'
lw_expect_eq "$(qmi_syslog | grep -c 'not readable, write to ipv4 unverified')" 1 'one line for the unverified write'
lw_expect_eq "$(qmi_syslog | grep -c -e 'internet.example' -e 'apn-disabled' || :)" 0 'no raw profile in the log'

# a write that fails: the start goes on as the stock handler does
qmi_fixture owner-sim
qmi_profile internet.example ipv4v6
qmi_fault '--modify-profile' 'error:Write failed'
qmi_debug
qmi_run setup ipv4 || lw_fail 'forced IPv4 with a failing write failed'
lw_expect_eq "$(qmi_notify 0 .data.pdh_4)" -12345678 'IPv4 published after a failed write'
lw_expect_eq "$(qmi_syslog | grep -c 'profile write to ipv4 failed')" 1 'one line for the failed write'

# a write that does not stick, in auto on the owner's SIM: the IPv6 call is refused because the
# profile is still IPV4, and that is not counted as a refusal of the operator
qmi_fixture owner-sim
qmi_fault '--modify-profile' nostick
qmi_debug
qmi_run setup ipv4v6 || lw_fail 'auto with a write that does not stick failed'
lw_expect_eq "$(qmi_notify 0 .data.pdh_4)" -12345678 'IPv4 published'
lw_expect_eq "$(qmi_notify 3 '.error[*]')" '' 'failed starts'
lw_expect_eq "$(qmi_syslog | grep -c 'did not stick')" 1 'the log says the write did not stick'
lw_expect_eq "$(qmi_syslog | grep -c 'not counted as refused')" 1 'the failed IPv6 call is not counted as refused'
lw_expect_eq "$(qmi_syslog | grep -c 'IPv6 refused')" 0 'no refusal line'
# The write succeeds, but the verify read times out. The IPv4-only operator
# needs a second write to put the modem profile back to IPv4.
qmi_fixture ip-only
qmi_profile internet.example ipv4
qmi_fault '--get-profile-settings' hang 1 1
qmi_run setup ipv4v6 || lw_fail 'IPv4 fallback used a stale profile after the verify timeout'
lw_expect_eq "$(qmi_notify 0 .data.pdh_4)" -12345678 'IPv4 fallback published'
lw_expect_eq "$(qmi_calls | grep -e --modify-profile)" \
    '--modify-profile 3gpp,1 --apn internet.example --pdp-type ipv4v6
--modify-profile 3gpp,1 --apn internet.example --pdp-type ipv4' 'both profile writes'

echo ok
