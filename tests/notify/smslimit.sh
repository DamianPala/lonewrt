# R46c: at most 10 replies in a day, in all; the counter survives a restart and is written to flash
# only when a reply is sent; after the limit commands get no reply, REBOOT still restarts the router;
# the allowance comes back as the replies get a day old.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup ''
ADMIN=+48000000001
admins_set "$ADMIN"
lw_net up down
passes 2
LOG=/etc/lw-notify/sms-replies
# stamp: inode, size and content of the counter file
stamp() { find "$LOG" -exec ls -li {} + | cut -d' ' -f1,5; md5sum "$LOG"; }

[ ! -e "$LOG" ] || lw_fail "counter file before the first reply"
sms_cmd "$ADMIN" HELP
lw_expect_eq "$(wc -l <"$LOG" | tr -d ' ')" 1 "counter lines after one reply"
i=1
while [ "$i" -lt 10 ]; do
    sms_cmd "$ADMIN" STATUS
    i=$((i + 1))
done
lw_expect_eq "$(sms_out)" 10 "replies up to the limit"
lw_expect_eq "$(wc -l <"$LOG" | tr -d ' ')" 10 "counter lines"

# the 11th gets nothing, one syslog entry says why, and the counter file is not touched
before=$(stamp)
: >"$T/syslog"
sms_cmd "$ADMIN" STATUS
sms_cmd "$ADMIN" HELP
lw_expect_eq "$(sms_out)" 10 "replies over the limit"
lw_expect_eq "$(grep -c 'lw-notify: SMS control: 10 replies in the last day' "$T/syslog")" 1 "limit entries"
lw_expect_eq "$(stamp)" "$before" "counter file after commands over the limit"
# nor does an SMS from a number off the list or a normal pass touch it
sms_cmd +48000000099 STATUS
passes 5
lw_expect_eq "$(stamp)" "$before" "counter file after other traffic"

# REBOOT after the limit: no reply, but the router restarts
sms_cmd "$ADMIN" REBOOT
lw_expect_eq "$(sms_out)" 10 "replies to REBOOT over the limit"
lw_expect_eq "$(reboots_n)" 1 "restarts for REBOOT over the limit"
lw_expect_eq "$(stamp)" "$before" "counter file after REBOOT over the limit"

# the restart does not reset the counter
reboot_sim 90
passes 3
sms_cmd "$ADMIN" STATUS
lw_expect_eq "$(sms_out)" 10 "replies after a restart"
lw_expect_eq "$(wc -l <"$LOG" | tr -d ' ')" 10 "counter lines after a restart"
lw_expect_eq "$(reboots_n)" 1 "restarts after the restart (the REBOOT is not run again)"

# a day later the allowance is back; the counter file keeps only what is still counted
wall_add 86400
sms_cmd "$ADMIN" STATUS
lw_expect_eq "$(sms_out)" 11 "reply a day later"
lw_expect_eq "$(wc -l <"$LOG" | tr -d ' ')" 1 "counter lines a day later"

# a clock that went back counts the newer replies, so the limit cannot be passed that way
i=1
while [ "$i" -lt 10 ]; do
    sms_cmd "$ADMIN" HELP
    i=$((i + 1))
done
lw_expect_eq "$(sms_out)" 20 "replies in the new day"
wall_add -3600
sms_cmd "$ADMIN" HELP
lw_expect_eq "$(sms_out)" 20 "reply after the clock went back"
echo ok
