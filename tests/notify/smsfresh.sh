# R46b, D65: a REBOOT by SMS restarts only when it is fresh and under the daily limit. Fresh: it
# appeared in memory after the service started (what the first scan finds is old), and, with a
# synced clock, its SMSC time is at most SMS_REBOOT_MAX_AGE_MIN minutes before or after now
# (without NTP there is nothing to compare). A stale or over-limit REBOOT
# gets a reply with the reason (one of the 10 replies of R46c) and restarts nothing. At most
# SMS_REBOOT_MAX_PER_DAY restarts per day; the counter is a file on flash, written only when it
# changes, and it survives a restart. All numbers here are fake.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
export LW_SMSCTL_MAX=1000
notify_setup ''
ADMIN=+48000000001
STALE_START='Home router: reboot not done, it was already waiting when the router started. Send it again.'
LOG=/etc/lw-notify/sms-reboots
admins_set "$ADMIN"
lw_net up down
# the limit of the day is out of the way until its own part
uci -q set lonewrt.notify.sms_reboot_max_day=50
uci -q commit lonewrt
passes 3

# stamp: inode, size and content of the restart counter (it must not be touched when nothing changes)
stamp() { find "$LOG" -exec ls -li {} + | cut -d' ' -f1,5; md5sum "$LOG"; }
# reboot_ok TS: a REBOOT with that SMSC time restarts the router once
reboot_ok() {
    _r=$(reboots_n)
    sms_cmd "$ADMIN" REBOOT "$1"
    lw_expect_eq "$(reboots_n)" $((_r + 1)) "restarts for a REBOOT stamped '$1'"
    lw_expect_eq "$(sms_body "$(sms_out)")" 'Home router: restarting now, back in about 2 min.' "reply"
}
# reboot_refused TS TEXT: a REBOOT with that time gets TEXT and restarts nothing
reboot_refused() {
    _r=$(reboots_n)
    _n=$(sms_out)
    sms_cmd "$ADMIN" REBOOT "$1"
    lw_expect_eq "$(reboots_n)" "$_r" "restarts for a REBOOT stamped '$1'"
    lw_expect_eq "$(sms_out)" $((_n + 1)) "replies to a refused REBOOT stamped '$1'"
    lw_expect_eq "$(sms_body $((_n + 1)))" "$2" "reason for a REBOOT stamped '$1'"
}
AGE10='Home router: reboot not done, the SMS is older than 10 min or has no time. Send it again.'

# --- the age: 10 min by default
reboot_ok "$(smsc_ts -300)"
reboot_ok "$(smsc_ts -590)"
reboot_refused "$(smsc_ts -660)" "$AGE10"
reboot_refused "$(smsc_ts -86400)" "$AGE10"
# a time a little in the future (the SMSC clock runs ahead) is fresh; more than the limit ahead
# means the clocks or zones disagree, and it is not
reboot_ok "$(smsc_ts 300)"
reboot_refused "$(smsc_ts 660)" "$AGE10"
# with the clock synced, a time that cannot be read is not fresh
reboot_refused '' "$AGE10"
reboot_refused 'soon' "$AGE10"
# without NTP the router has no time to compare with: the age is not checked
ntp_off
reboot_ok '11/07/20 01:00:00'
ntp_on
# the limit comes from the profile (uci lonewrt.notify.sms_reboot_max_age)
uci -q set lonewrt.notify.sms_reboot_max_age=3
uci -q commit lonewrt
reboot_ok "$(smsc_ts -120)"
reboot_refused "$(smsc_ts -300)" 'Home router: reboot not done, the SMS is older than 3 min or has no time. Send it again.'
uci -q delete lonewrt.notify.sms_reboot_max_age
uci -q commit lonewrt
reboot_ok "$(smsc_ts -500)"
# an invalid value falls back to the default
uci -q set lonewrt.notify.sms_reboot_max_age=abc
uci -q commit lonewrt
reboot_refused "$(smsc_ts -660)" "$AGE10"
uci -q delete lonewrt.notify.sms_reboot_max_age
uci -q commit lonewrt

# --- what the first scan of a start finds is old, even when it is fresh by its time
reboot_sim 90
ntp_on
wall_set '2026-11-07 12:00'
sms_put "$ADMIN" REBOOT "$(smsc_ts -30)"
passes 3
lw_expect_eq "$(sms_body "$(sms_out)")" "$STALE_START" "reply to a REBOOT waiting at the start"
_r=$(reboots_n)
lw_expect_eq "$_r" 6 "restarts after the stale REBOOT at the start (the earlier ones only)"
# a STATUS waiting at the start is answered all the same; only the restart is held back
sms_put "$ADMIN" STATUS "$(smsc_ts -30)"
passes 3
case $(sms_body "$(sms_out)") in
    'Home router: internet '*) ;;
    *) lw_fail "STATUS after the start: $(sms_body "$(sms_out)")" ;;
esac
# a REBOOT that arrives after the first scan works
reboot_ok "$(smsc_ts -5)"
# the REBOOT that was stale at the start is not looked at again
passes 4
lw_expect_eq "$(reboots_n)" $((_r + 1)) "restarts after more passes"

# --- the limit per day: 5 by default
rm -f "$LOG"
uci -q delete lonewrt.notify.sms_reboot_max_day
uci -q commit lonewrt
LIMIT5='Home router: reboot not done, 5 restarts by SMS in the last day. Try again later.'
i=0
while [ "$i" -lt 5 ]; do
    reboot_ok "$(smsc_ts -5)"
    i=$((i + 1))
done
lw_expect_eq "$(wc -l <"$LOG" | tr -d ' ')" 5 "counted restarts"
before=$(stamp)
reboot_refused "$(smsc_ts -5)" "$LIMIT5"
# a command that is not a restart, and the refusal itself, do not write the counter
sms_cmd "$ADMIN" STATUS
lw_expect_eq "$(stamp)" "$before" "restart counter after refused and other commands"
# it survives a restart
reboot_sim 90
ntp_on
passes 3
reboot_refused "$(smsc_ts -5)" "$LIMIT5"
lw_expect_eq "$(stamp)" "$before" "restart counter after a restart"
# the profile sets the limit (uci lonewrt.notify.sms_reboot_max_day)
uci -q set lonewrt.notify.sms_reboot_max_day=6
uci -q commit lonewrt
reboot_ok "$(smsc_ts -5)"
reboot_refused "$(smsc_ts -5)" 'Home router: reboot not done, 6 restarts by SMS in the last day. Try again later.'
# a day later the first ones are out of the window
wall_add 90000
reboot_ok "$(smsc_ts -5)"
lw_expect_eq "$(wc -l <"$LOG" | tr -d ' ')" 1 "counted restarts a day later"

# --- the refusal is one of the replies of R46c: none left, no refusal and still no restart
uci -q delete lonewrt.notify.sms_reboot_max_day
uci -q commit lonewrt
i=0
while [ "$i" -lt 4 ]; do
    reboot_ok "$(smsc_ts -5)"
    i=$((i + 1))
done
export LW_SMSCTL_MAX=0
_r=$(reboots_n)
_n=$(sms_out)
sms_cmd "$ADMIN" REBOOT "$(smsc_ts -5)"
lw_expect_eq "$(reboots_n)" "$_r" "restarts over both limits"
lw_expect_eq "$(sms_out)" "$_n" "replies over the limit of replies"
export LW_SMSCTL_MAX=1000

# --- a restart counter that cannot be written means no restart (the limit would mean nothing)
wall_add 90000
mv_fail /lw-notify/sms-reboots
: >"$T/syslog"
_r=$(reboots_n)
sms_cmd "$ADMIN" REBOOT "$(smsc_ts -5)"
lw_expect_eq "$(reboots_n)" "$_r" "restarts when the counter cannot be saved"
lw_expect_grep "$T/syslog" 'lw-notify: SMS control: the restart counter cannot be saved, no restart'
mv_ok

# --- a first scan whose seen list cannot be saved is still the first scan: the REBOOT that waited
# at the start does not restart on the read after it
reboot_sim 90
ntp_on
mv_fail /lw-notify/seen
sms_put "$ADMIN" REBOOT "$(smsc_ts -30)"
passes 3
mv_ok
_r=$(reboots_n)
passes 22
lw_expect_eq "$(reboots_n)" "$_r" "restarts for a REBOOT at a start whose seen list was not saved"
lw_expect_eq "$(sms_body "$(sms_out)")" "$STALE_START" "reply to it once the seen list is saved"
echo ok
