# R73q, D217: a SIM or APN on which every call is refused must not keep writing profile 1 of the
# modem. After 3 Auto starts in a row that ended with every step refused (verified refusals only), the
# following Auto starts run step 1 only, with no profile write and no rollback; once per 60 min one
# Auto start runs the whole order again. The count resets on a call that comes up, on a change of the
# APN, and with the RAM state (boot); forced IPv4 and forced IPv6 are unchanged. The numbers are
# constants that LW_CAP_STARTS and LW_CAP_SECONDS override.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

S=/var/run/lw-family/refused

# fails [MODE]: one start that must fail, with the call log emptied; its profile writes in $w
fails() {
    : >"$QMI_STATE/uqmi.jsonl"
    qmi_run setup "${1:-ipv4v6}" >/dev/null && lw_fail 'a start with every call refused succeeded'
    w=$(qmi_count '--modify-profile')
}

# clock_set SECOND: the uptime clock the handler reads
clock_set() { printf '%s.00 %s.00\n' "$1" "$1" >"$LW_UPTIME_FILE"; }

# cap_lines TEXT: how many lines of the handler's log hold TEXT
cap_lines() { qmi_syslog | grep -c -e "$1" || :; }

# an Auto router whose profile holds IPV4V6: a full refused start writes IP, IPV6 and the rollback
engaged_fixture() {
    qmi_fixture both-refused
    qmi_profile internet.example ipv4v6
    local n
    for n in 1 2 3; do
        fails
        lw_expect_eq "$w" 3 "full start $n: IP, IPV6 and the rollback are written"
        lw_expect_eq "$(qmi_arg_count --start-network)" 4 "full start $n: all calls"
    done
}

# the first three starts are full, the next ones run step 1 only and write nothing
engaged_fixture
lw_expect_eq "$(cap_lines 'write cap: 3 starts in a row')" 1 'one line when the reduced mode starts'
lw_expect_eq "$(qmi_syslog | wc -l)" 1 'no other line at the info level'
lw_expect_eq "$(cut -d' ' -f1,3 $S)" '3 internet.example' 'the count and the APN in the RAM state'
lw_expect_eq "$(ls -ld /var/run/lw-family | cut -c1-10)" drwx------ 'the state is in the family directory'
for n in 4 5 6; do
    fails
    lw_expect_eq "$w" 0 "reduced start $n: no profile write"
    lw_expect_eq "$(qmi_arg_count --start-network)" 2 "reduced start $n: step 1 only"
    lw_expect_eq "$(cat "$QMI_STATE/profile.pdp")" ipv4v6 "reduced start $n: no rollback, the type stays"
done
lw_expect_eq "$(qmi_syslog | wc -l)" 1 'the reduced starts log nothing at the info level'
lw_expect_eq "$(qmi_notify 3 '.error[*]' | sort -u)" CALL_FAILED 'a reduced start still fails once for netifd'

# a full start once per hour: not at 3599 s after the last full start, at 3600 s
last=$(cut -d' ' -f2 $S)
clock_set $((last + 3599))
fails
lw_expect_eq "$w" 0 'just under the hour: reduced'
clock_set $((last + 3600))
fails
lw_expect_eq "$w" 3 'at the hour: the whole order again'
lw_expect_eq "$(qmi_arg_count --start-network)" 4 'at the hour: all calls'
lw_expect_eq "$(cap_lines 'write cap: full start after 60 min')" 1 'one line for the hourly start'
lw_expect_eq "$(cut -d' ' -f1,2 $S)" "4 $((last + 3600))" 'the hourly start counts and takes the slot'
fails
lw_expect_eq "$w" 0 'after the hourly start: reduced again'
lw_expect_eq "$(cap_lines 'write cap: full start')" 1 'no second line without a second hourly start'
clock_set $((last + 7200))
fails
lw_expect_eq "$w" 3 'the next hour: the whole order again'
lw_expect_eq "$(cap_lines 'write cap: full start')" 2 'one line per hourly start'
lw_expect_eq "$(cap_lines 'write cap: 3 starts in a row')" 1 'the reduced mode did not start again'

# a SIM or operator that starts to accept a call: found by the hourly start, and the count is gone
clock_set $((last + 10800))
cp "$QMI_DIR/scenarios/ip-only" "$QMI_STATE/scenario"
: >"$QMI_STATE/uqmi.jsonl"
qmi_run setup ipv4v6 >/dev/null || lw_fail 'the hourly start did not find the accepted IP step'
lw_expect_eq "$(qmi_notify 0 .data.pdh_4 | grep -c .)" 1 'IPv4 published by the hourly start'
[ ! -e $S ] || lw_fail 'the state stays after a call came up'
lw_expect_eq "$(cap_lines 'write cap off: a call came up')" 1 'one line when the count resets after the cap was engaged'
qmi_ifdown ipv4v6

# a call that comes up in a reduced start resets too, and the count starts over
engaged_fixture
cp "$QMI_DIR/scenarios/owner-sim" "$QMI_STATE/scenario"
: >"$QMI_STATE/uqmi.jsonl"
qmi_run setup ipv4v6 >/dev/null || lw_fail 'the reduced start did not come up on a granted call'
lw_expect_eq "$(qmi_count '--modify-profile')" 0 'the reduced start that came up wrote nothing'
[ ! -e $S ] || lw_fail 'the state stays after a call came up in a reduced start'
lw_expect_eq "$(cap_lines 'write cap off: a call came up')" 1 'one line for the reset'
qmi_ifdown ipv4v6
cp "$QMI_DIR/scenarios/both-refused" "$QMI_STATE/scenario"
for n in 1 2 3; do
    fails
    lw_expect_eq "$w" 3 "after the reset, full start $n"
done
fails
lw_expect_eq "$w" 0 'after the reset the cap engages again after 3 refused starts'
lw_expect_eq "$(cap_lines 'write cap: 3 starts in a row')" 2 'its line comes again'

# a start with a healthy modem leaves no state and no new line
qmi_fixture both-accepted
qmi_profile internet.example ipv4v6
qmi_run setup ipv4v6 >/dev/null || lw_fail 'a healthy start failed'
[ ! -e $S ] || lw_fail 'a healthy start left state'
lw_expect_eq "$(qmi_syslog)" '' 'a healthy start logs nothing'
qmi_ifdown ipv4v6

# a change of the APN the start uses resets the count, so the new APN gets its full starts
engaged_fixture
QMI_APN=other.example fails
lw_expect_eq "$w" 4 'a new APN: the whole order, APN, steps and rollback written'
lw_expect_eq "$(cap_lines 'write cap off: the APN changed')" 1 'one line for the reset by the APN'
lw_expect_eq "$(cut -d' ' -f1,3 $S)" '1 other.example' 'the count starts over for the new APN'
QMI_APN=other.example fails
lw_expect_eq "$w" 3 'second start of the new APN: full'
QMI_APN=other.example fails
lw_expect_eq "$w" 3 'third start of the new APN: full'
QMI_APN=other.example fails
lw_expect_eq "$w" 0 'then the cap engages for the new APN'
lw_expect_eq "$(cap_lines 'write cap: 3 starts in a row')" 2 'its line'
# the empty APN is an APN too
QMI_APN='' fails
lw_expect_eq "$(cap_lines 'write cap off: the APN changed')" 2 'a change to the empty APN resets'
lw_expect_eq "$(cut -d' ' -f1,3 $S)" '1 -' 'the empty APN in the state'

# forced IPv4 and forced IPv6 use their usual call steps; only a success changes the count
engaged_fixture
before=$(cat $S)
lines=$(qmi_syslog | wc -l)
fails ipv4
lw_expect_eq "$w" 2 'forced IPv4 under the cap: the write and the rollback of today'
fails ipv6
lw_expect_eq "$w" 2 'forced IPv6 under the cap: the write and the rollback of today'
lw_expect_eq "$(cat $S)" "$before" 'forced starts leave the count'
lw_expect_eq "$(qmi_syslog | wc -l)" "$lines" 'forced starts log nothing new'
cp "$QMI_DIR/scenarios/ip-only" "$QMI_STATE/scenario"
qmi_run setup ipv4 >/dev/null || lw_fail 'the forced IPv4 start did not come up'
[ ! -e "$S" ] || lw_fail 'the state stays after a forced IPv4 call came up'
qmi_ifdown ipv4
qmi_fixture both-refused
qmi_profile internet.example ipv4v6
for n in 1 2 3 4; do fails ipv4; done
[ ! -e $S ] || lw_fail 'a forced refused start made a count'
fails
lw_expect_eq "$w" 3 'Auto after forced refusals: still a full start'
lw_expect_eq "$(cat $S | cut -d' ' -f1)" 1 'the first Auto start is the first of the count'

# a start that is no verified refusal neither counts nor resets: no client, an unreadable profile
qmi_fixture both-refused
qmi_profile internet.example ipv4v6
fails
fails
lw_expect_eq "$(cut -d' ' -f1 $S)" 2 'two counted starts'
printf '0\n' >"$QMI_STATE/cid-limit"
fails
rm -f "$QMI_STATE/cid-limit"
lw_expect_eq "$(cut -d' ' -f1 $S)" 2 'a start without a client does not count'
for fault in 'error:Invalid client ID' 'reply:"Call failed"' 'reply:"Request timed out"'; do
    qmi_fault '--start-network' "$fault" 0 1
    fails
    lw_expect_eq "$(cut -d' ' -f1 $S)" 2 "a broken start ($fault) does not count"
    rm -f "$QMI_STATE/fault" "$QMI_STATE/fault.1"
done
qmi_fault '--modify-profile' nostick 2 1
fails
lw_expect_eq "$(cut -d' ' -f1 $S)" 2 'an unverified rollback does not count'
rm -f "$QMI_STATE/fault" "$QMI_STATE/fault.1"
qmi_profile internet.example ipv4v6
qmi_fault '--get-profile-settings' 'error:Not supported'
fails
lw_expect_eq "$w" 3 'an unreadable profile is written at every step as before, with no rollback'
lw_expect_eq "$(cut -d' ' -f1 $S)" 2 'an unverified start does not count'
rm -f "$QMI_STATE/fault"
qmi_fault '--modify-profile' nostick
fails
lw_expect_eq "$(cut -d' ' -f1 $S)" 2 'a write that does not stick does not count'
rm -f "$QMI_STATE/fault"
qmi_profile internet.example ipv4v6
fails
lw_expect_eq "$(cut -d' ' -f1 $S)" 3 'the next verified refusal makes the third'
lw_expect_eq "$(cap_lines 'write cap: 3 starts in a row')" 1 'and starts the reduced mode'
# under the cap, a start that is no refusal does not reset either
printf '0\n' >"$QMI_STATE/cid-limit"
fails
rm -f "$QMI_STATE/cid-limit"
lw_expect_eq "$(cut -d' ' -f1 $S)" 3 'a start without a client does not reset'
lw_expect_eq "$(cap_lines 'write cap off')" 0 'no reset line'
fails
lw_expect_eq "$w" 0 'still reduced'

SIM=8900000000000000001

#@ s1 the hourly slot is spent only when the full order ran its calls
engaged_fixture
last=$(cut -d' ' -f2 $S)
clock_set $((last + 3600))
printf '0\n' >"$QMI_STATE/cid-limit"
fails
lw_expect_eq "$(qmi_arg_count --start-network)" 0 'a transient failure at the hourly start: no call made'
lw_expect_eq "$(cut -d' ' -f2 $S)" "$last" 'the hourly slot is not spent by it'
rm -f "$QMI_STATE/cid-limit"
fails
lw_expect_eq "$w" 3 'the next start is the hourly full one'
lw_expect_eq "$(qmi_arg_count --start-network)" 4 'it makes all calls'
lw_expect_eq "$(cut -d' ' -f2 $S)" $((last + 3600)) 'now the slot is spent'
fails
lw_expect_eq "$w" 0 'and the following start is reduced'
# a refused hourly start with an unverified write still ran its calls: it spends the slot
engaged_fixture
clock_set $((last + 3600))
qmi_fault '--modify-profile' nostick 0 1
fails
lw_expect_eq "$(qmi_arg_count --start-network)" 4 'an unverified hourly start made all calls'
lw_expect_eq "$(cut -d' ' -f2 $S)" $((last + 3600)) 'it spends the slot'
rm -f "$QMI_STATE/fault" "$QMI_STATE/fault.1"

#@ s2 the repair before registration runs for forced, full and hourly starts, not for reduced ones
# a record of a change that a cut-off start began, profile 1 left at IPV6 by it
cut_off() {
    printf 'change ipv4v6 internet.example %s\n' "$SIM" >/etc/lw-wwan-ptype
    qmi_profile internet.example ipv6
    : >"$QMI_STATE/uqmi.jsonl"
}
repaired() {
    local fix reg
    fix=$(qmi_first_line '--modify-profile 3gpp,1 --apn internet.example --pdp-type ipv4v6$')
    reg=$(qmi_first_line '--network-register')
    [ "$fix" -gt 0 ] && [ "$fix" -lt "$reg" ]
}
last=1000
engaged_fixture
cut_off
qmi_run setup ipv4 >/dev/null && lw_fail 'forced IPv4 with every call refused succeeded'
repaired || lw_fail 'forced IPv4 under the cap got no repair before registration'
engaged_fixture
cut_off
clock_set $((last + 3600))
qmi_run setup ipv4v6 >/dev/null && lw_fail 'the hourly start succeeded'
repaired || lw_fail 'the hourly full start got no repair before registration'
engaged_fixture
cut_off
qmi_run setup ipv4v6 >/dev/null && lw_fail 'the reduced start succeeded'
! repaired || lw_fail 'a reduced start got a repair before registration'
lw_expect_eq "$(qmi_count '--modify-profile')" 1 'the reduced start writes the type of step 1 only'
# a full start before the cap engages keeps its repair (R73n)
qmi_fixture both-refused
qmi_profile internet.example ipv4v6
fails
cut_off
qmi_run setup ipv4v6 >/dev/null && lw_fail 'a full start succeeded'
repaired || lw_fail 'a full start got no repair before registration'

#@ s3 an unverified repair write does not count
qmi_fixture both-refused
printf 'change ipv4 internet.example %s\n' "$SIM" >/etc/lw-wwan-ptype
qmi_profile internet.example ipv6
qmi_fault '--modify-profile' nostick 0 1
fails
[ ! -e $S ] || lw_fail 'a start whose repair write did not stick counted'
rm -f "$QMI_STATE/fault" "$QMI_STATE/fault.1"
qmi_fixture both-refused
printf 'change ipv4 internet.example %s\n' "$SIM" >/etc/lw-wwan-ptype
qmi_profile internet.example ipv6
qmi_fault '--modify-profile' 'error:Write failed' 0 1
fails
[ ! -e $S ] || lw_fail 'a start whose repair write failed counted'
rm -f "$QMI_STATE/fault" "$QMI_STATE/fault.1"
qmi_fixture both-refused
printf 'change ipv4 internet.example %s\n' "$SIM" >/etc/lw-wwan-ptype
qmi_profile internet.example ipv6
fails
lw_expect_eq "$(cut -d' ' -f1 $S)" 1 'a verified repair leaves the start a counted one'

#@ s4 the key holds the effective APN of both families
with_v6() { : >"$QMI_STATE/uqmi.jsonl"; qmi_run setup ipv4v6 "\"v6apn\":\"$1\"" >/dev/null && lw_fail 'a refused start succeeded'; w=$(qmi_count '--modify-profile'); }
engaged_fixture
with_v6 internet.example
lw_expect_eq "$w" 0 'a v6apn equal to the APN is the same key: reduced'
with_v6 v6.example
lw_expect_eq "$(qmi_arg_count --start-network)" 4 'a change of v6apn alone: the whole order'
lw_expect_eq "$(cap_lines 'write cap off: the APN changed')" 1 'one line for the reset'
lw_expect_eq "$(cut -d' ' -f1,3,4 $S)" '1 internet.example v6.example' 'the key holds both APNs'
with_v6 v6.example
with_v6 v6.example
with_v6 v6.example
lw_expect_eq "$(qmi_arg_count --start-network)" 2 'the cap engages for the new pair'
with_v6 other6.example
lw_expect_eq "$(qmi_arg_count --start-network)" 4 'another v6apn resets again'

#@ s5 profile corrections of reduced starts are bounded between full starts
engaged_fixture
last=$(cut -d' ' -f2 $S)
qmi_fault '--get-profile-settings' 'error:Not supported'
fails
lw_expect_eq "$w" 1 'a reduced start with an unreadable profile writes once'
lw_expect_eq "$(qmi_arg_count --start-network)" 2 'and still makes both calls of step 1'
fails
lw_expect_eq "$w" 0 'the next reduced start does not write again'
lw_expect_eq "$(qmi_arg_count --start-network)" 2 'it still makes both calls'
fails
lw_expect_eq "$w" 0 'nor the one after'
clock_set $((last + 3600))
fails
lw_expect_eq "$(qmi_arg_count --start-network)" 4 'the hourly full start'
fails
lw_expect_eq "$w" 1 'after a full start one correction is allowed again'
fails
lw_expect_eq "$w" 0 'and only one'
rm -f "$QMI_STATE/fault" "$QMI_STATE/fault.1"
# a write that does not stick is not retried by the next reduced start either
engaged_fixture
qmi_profile internet.example ipv4
qmi_fault '--modify-profile' nostick
fails
lw_expect_eq "$w" 1 'a reduced start writes the type of step 1 once'
fails
lw_expect_eq "$w" 0 'a write that did not stick is not retried before the next full start'
rm -f "$QMI_STATE/fault" "$QMI_STATE/fault.1"

#@ s6 the hourly slot is spent only when every call of the full order was sent
engaged_fixture
last=$(cut -d' ' -f2 $S)
clock_set $((last + 3600))
qmi_fault '--set-ip-family' 'error:Failed to set the family'
fails
lw_expect_eq "$(qmi_arg_count --start-network)" 0 'a hourly start whose family selection fails sends no call'
lw_expect_eq "$(cut -d' ' -f2 $S)" "$last" 'it leaves the slot'
rm -f "$QMI_STATE/fault" "$QMI_STATE/fault.1"
# the operator now grants IPV6 only: the next start is the hourly one and gets it
cp "$QMI_DIR/scenarios/ipv6-profile-only" "$QMI_STATE/scenario"
: >"$QMI_STATE/uqmi.jsonl"
qmi_run setup ipv4v6 >/dev/null || lw_fail 'the next start did not find the IPV6 step'
lw_expect_eq "$(qmi_notify 0 .data.pdh_6 | grep -c .)" 1 'the IPv6 call is up'
lw_expect_eq "$(cap_lines 'write cap off: a call came up')" 1 'and the count is gone'
qmi_ifdown ipv4v6

#@ s7 one decision per start: the hour that passes during registration changes nothing
last=1000
engaged_fixture
printf 'change ipv4v6 internet.example %s\n' "$SIM" >/etc/lw-wwan-ptype
qmi_profile internet.example ipv6
clock_set $((last + 3599))
qmi_fault '--network-register' slow:2
: >"$QMI_STATE/uqmi.jsonl"
qmi_run setup ipv4v6 >/dev/null && lw_fail 'the start succeeded'
lw_expect_eq "$(qmi_arg_count --start-network)" 2 'planned reduced before registration: reduced after it'
reg=$(qmi_first_line '--network-register')
first=$(qmi_first_line '--modify-profile')
[ "$first" -gt "$reg" ] || lw_fail 'a reduced start repaired before registration'
lw_expect_eq "$(qmi_count '--modify-profile')" 1 'one write, the correction of step 1'
rm -f "$QMI_STATE/fault" "$QMI_STATE/fault.1"
# the other way round: due before registration, full after it, repair before registration
engaged_fixture
printf 'change ipv4v6 internet.example %s\n' "$SIM" >/etc/lw-wwan-ptype
qmi_profile internet.example ipv6
clock_set $((last + 3600))
qmi_fault '--network-register' slow:2
: >"$QMI_STATE/uqmi.jsonl"
qmi_run setup ipv4v6 >/dev/null && lw_fail 'the hourly start succeeded'
lw_expect_eq "$(qmi_arg_count --start-network)" 4 'the hourly start runs the whole order'
reg=$(qmi_first_line '--network-register')
first=$(qmi_first_line '--modify-profile')
[ "$first" -gt 0 ] && [ "$first" -lt "$reg" ] || lw_fail 'the hourly start got no repair before registration'

#@ end
# A failed state update must not give every reduced start another profile correction.
engaged_fixture
mkdir -p "$QMI_STATE/bin"
cat >"$QMI_STATE/bin/mv" <<'SH'
#!/bin/sh
[ "$3" != /var/run/lw-family/refused ] || exit 1
exec /bin/busybox mv "$@"
SH
chmod +x "$QMI_STATE/bin/mv"
qmi_fault '--get-profile-settings' 'error:Not supported'
PATH="$QMI_STATE/bin:$PATH" fails
lw_expect_eq "$w" 0 'without a recorded correction the reduced start cannot write'
lw_expect_eq "$(qmi_arg_count --start-network)" 2 'both reduced calls still run'

# the numbers are constants that tests override
qmi_fixture both-refused
qmi_profile internet.example ipv4v6
LW_CAP_STARTS=2 LW_CAP_SECONDS=120 fails
LW_CAP_STARTS=2 LW_CAP_SECONDS=120 fails
LW_CAP_STARTS=2 LW_CAP_SECONDS=120 fails
lw_expect_eq "$w" 0 'two starts engage the cap when LW_CAP_STARTS is 2'
clock_set 1119
LW_CAP_STARTS=2 LW_CAP_SECONDS=120 fails
lw_expect_eq "$w" 0 'under the shorter period: reduced'
clock_set 1120
LW_CAP_STARTS=2 LW_CAP_SECONDS=120 fails
lw_expect_eq "$w" 3 'at the shorter period: full'
lw_expect_eq "$(cap_lines 'full start after 2 min')" 1 'the line names the period'

# profile 1 not at IPV4V6 when the cap engages: the reduced start writes the type of step 1 once
qmi_fixture both-refused
qmi_profile internet.example ipv4
for n in 1 2 3; do
    fails
    lw_expect_eq "$w" 4 "full start $n from IPV4: step writes and the rollback"
done
lw_expect_eq "$(cat "$QMI_STATE/profile.pdp")" ipv4 'the rollback of the full starts'
fails
lw_expect_eq "$w" 1 'the first reduced start writes IPV4V6 once'
lw_expect_eq "$(qmi_calls | grep -e '--modify-profile')" '--modify-profile 3gpp,1 --apn internet.example --pdp-type ipv4v6' 'the write'
lw_expect_eq "$(cat "$QMI_STATE/profile.pdp")" ipv4v6 'no rollback after it'
fails
lw_expect_eq "$w" 0 'the next reduced start writes nothing'

# a family directory that fails the check of the RAM state rule gives no state: every start is full
qmi_fixture both-refused
qmi_profile internet.example ipv4v6
D=/var/run/lw-family
rm -rf "$D" /tmp/elsewhere
mkdir /tmp/elsewhere
ln -s /tmp/elsewhere "$D"
for n in 1 2 3 4 5; do
    fails
    lw_expect_eq "$w" 3 "start $n without a usable state directory is full"
done
lw_expect_eq "$(ls -A /tmp/elsewhere)" '' 'nothing written through the link'
rm -f "$D"
rm -rf /tmp/elsewhere

# a state file that does not parse is no state
qmi_fixture both-refused
qmi_profile internet.example ipv4v6
mkdir -p /var/run/lw-family
chmod 0700 /var/run/lw-family
A=internet.example
for junk in 'x y z' '5' "5 99999 $A $A 0" "-1 5 $A $A 0" '9 5' "5 08 $A $A 0" "5 1:0 $A $A 0" \
    "999999999999999999999 1000 $A $A 0" "5 1000 $A" "5 1000 $A $A" "5 1000 $A $A 2" \
    "5 1000 $A $A 0 extra"; do
    printf '%s\n' "$junk" >$S
    fails
    lw_expect_eq "$w" 3 "the record '$junk' is no state: a full start"
    lw_expect_eq "$(cut -d' ' -f1 $S)" 1 "the record '$junk' starts the count over"
done
printf '5 1000 %s %s 0\n  ' "$A" "$A" >$S
fails
lw_expect_eq "$w" 3 'a second line without a newline is malformed even if it is only spaces'
echo ok
