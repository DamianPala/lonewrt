# R73f: profile 1 holds the APN and the PDP type of the step. A start writes it only when the APN or
# the type differs or the profile is disabled, also for an empty APN; a change of the login alone
# goes on the next call and never into the profile. The stock handler wrote at every start.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

writes() { qmi_count '--modify-profile'; }

# the APN `a` at IPV4V6, the start with `a`: no write
qmi_fixture owner-sim
qmi_profile a ipv4v6
QMI_APN=a qmi_run setup ipv4v6 || lw_fail 'setup failed'
lw_expect_eq "$(writes)" 0 'a profile that matches is not written'
lw_expect_eq "$(qmi_count '--get-profile-settings')" 1 'the profile is read once'
qmi_ifdown ipv4v6

# the APN becomes `b`: one write, then the profile holds it; started again unchanged: no write
QMI_APN=b qmi_run setup ipv4v6 || lw_fail 'setup with the new APN failed'
lw_expect_eq "$(writes)" 1 'a changed APN is written'
lw_expect_eq "$(cat "$QMI_STATE/profile.apn")" b 'APN in the profile'
lw_expect_eq "$(qmi_calls | grep -e '--modify-profile')" '--modify-profile 3gpp,1 --apn b --pdp-type ipv4v6' 'the write'
qmi_ifdown ipv4v6
QMI_APN=b qmi_run setup ipv4v6 || lw_fail 'unchanged setup failed'
lw_expect_eq "$(writes)" 1 'an unchanged start writes nothing more'
qmi_ifdown ipv4v6

# only the password changes: the next call carries it, the profile gets no write
QMI_APN=b qmi_run setup ipv4v6 '"auth":"pap","username":"user","password":"s3cret-pw"' ||
    lw_fail 'setup with a login failed'
lw_expect_eq "$(writes)" 1 'a changed login is no profile write'
lw_expect_eq "$(qmi_count 'wds,[0-9]* --start-network --apn b --auth-type pap --username user --password s3cret-pw')" 2 \
    'the login is on each call'
lw_expect_eq "$(qmi_calls | grep -e '--modify-profile' | grep -c -e s3cret-pw -e user || :)" 0 'no login in a profile write'
qmi_ifdown ipv4v6

# the right APN and type but disabled: written (the write enables the profile)
qmi_fixture owner-sim
qmi_profile a ipv4v6 off
QMI_APN=a qmi_run setup ipv4v6 || lw_fail 'setup with a disabled profile failed'
lw_expect_eq "$(writes)" 1 'a disabled profile is written'
[ ! -e "$QMI_STATE/profile.off" ] || lw_fail 'the profile is still disabled'

# the empty APN is written like any other, and skipped when the profile has it (R13a)
qmi_fixture owner-sim
qmi_profile internet.example ipv4v6
QMI_APN='' qmi_run setup ipv4v6 || lw_fail 'setup with an empty APN failed'
lw_expect_eq "$(writes)" 1 'an empty APN over another one is written'
lw_expect_eq "$(cat "$QMI_STATE/profile.apn")" '' 'empty APN in the profile'
lw_expect_eq "$(qmi_calls | grep -e '--modify-profile')" '--modify-profile 3gpp,1 --apn  --pdp-type ipv4v6' 'the write of an empty APN'
lw_expect_eq "$(qmi_count '--start-network --autoconnect')" 1 'the call has no --apn'
qmi_ifdown ipv4v6
QMI_APN='' qmi_run setup ipv4v6 || lw_fail 'second setup with an empty APN failed'
lw_expect_eq "$(writes)" 1 'a profile with the empty APN is not written again'

# a step that needs another type writes it: IPV4V6 refused, then IP (R73a)
qmi_fixture ip-only
qmi_profile internet.example ipv4
qmi_run setup ipv4v6 || lw_fail 'setup of the IP step failed'
lw_expect_eq "$(qmi_calls | grep -e '--modify-profile' | tr '\n' ',')" \
    '--modify-profile 3gpp,1 --apn internet.example --pdp-type ipv4v6,--modify-profile 3gpp,1 --apn internet.example --pdp-type ipv4,' \
    'a write per step that changes the type'
echo ok
