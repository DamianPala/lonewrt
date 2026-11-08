# R46, R46b: REBOOT from an admin number sends its reply first and restarts the router; the note for
# the chat is on flash at that moment; after the start the chat gets one "Router back" message with
# the sender's number (R45a), /status names the reason; the command never runs twice (no restart
# loop), not after the restart and not on the first pass after a flash or reset; a failed reply does
# not stop the restart.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup ''
ADMIN=+48000000001
admins_set "$ADMIN"
lw_net up down
nlbw_set "aa:bb:cc:00:00:01 1000000000 0"

# a REBOOT that waits in the store when the service starts for the first time (after a flash or a
# reset the old messages are still in the modem): recorded, not run
sms_in 1 +48000000001 '11/07/26 09:00:00' 'REBOOT'
passes 3
lw_expect_eq "$(sms_out)" 0 "replies to a command from before the first start"
lw_expect_eq "$(reboots_n)" 0 "restarts for a command from before the first start"
expect_sent 0

# a restart stand-in that tells what had happened before it: replies sent, note on flash
mkdir -p /opt/ks
cat >/opt/ks/reboot <<'EOF'
#!/bin/sh
if [ -f /etc/lw-notify/reboot ]; then n=yes; else n=no; fi
c=0
[ ! -f "$LW_TEST/sms-sent" ] || c=$(wc -l <"$LW_TEST/sms-sent" | tr -d ' ')
echo "reboot note=$n sms=$c" >>"$LW_TEST/events"
EOF
chmod +x /opt/ks/reboot
PATH=/opt/ks:$PATH
export PATH

lw_uptime_set 5000
reboot_wall=$(($(cat "$T/wall") + 2))
sms_cmd "$ADMIN" ' reboot '
lw_expect_eq "$(sms_out)" 1 "replies to REBOOT"
lw_expect_eq "$(sms_to 1)" "${ADMIN#+}" "reply goes to the sender"
lw_expect_eq "$(sms_body 1)" "Home router: restarting now, back in about 2 min." "REBOOT reply"
lw_expect_eq "$(reboots_n)" 1 "restarts"
lw_expect_eq "$(grep '^reboot' "$T/events")" "reboot note=yes sms=1" "reply sent and note on flash before the restart"
lw_expect_eq "$(sed -n 's/^name=//p' /etc/lw-notify/reboot)" "$ADMIN" "note: the number"
lw_expect_eq "$(sed -n 's/^via=//p' /etc/lw-notify/reboot)" sms "note: the channel"
lw_expect_eq "$(sed -n 's/^wall=//p' /etc/lw-notify/reboot)" "$reboot_wall" "note: time"
lw_expect_eq "$(wc -l <"$T/nlbw/commits" | tr -d ' ')" 1 "data counters committed before the restart"

# the router starts again: nothing while the clock is not set, then one message with the number
reboot_sim 30
ntp_off
wall_set '2026-11-07 11:20'
n=$(sent)
passes 3
lw_expect_eq "$(sent)" "$n" "messages while the clock is not set"
ntp_on
echo $((reboot_wall + 109)) >"$T/wall"
pass
lw_expect_eq "$(sent)" $((n + 1)) "messages after the clock is set"
lw_expect_eq "$(last_text)" "🟢 Router back after restart (asked by SMS from $ADMIN), down 1 min 50 s." \
    "Router back"
[ ! -e /etc/lw-notify/reboot ] || lw_fail "the note is still on flash after the message"
passes 5
lw_expect_eq "$(sent)" $((n + 1)) "messages after the first one (no repeat)"
# the command is still in the store, but it was handled: no second restart, no second reply
lw_expect_eq "$(reboots_n)" 1 "restarts after the start (no loop)"
lw_expect_eq "$(sms_out)" 1 "replies after the start"
tg_push "$TG_CHAT" /status
pass
case $(last_text) in
    *"(restarted by SMS from $ADMIN)"*) ;;
    *) lw_fail "/status after the restart: $(last_text)" ;;
esac
# a second restart by hand afterwards: no message and the usual reason
reboot_sim 30
passes 3
lw_expect_eq "$(sent)" $((n + 2)) "messages after a restart nobody asked for"

# a failed reply does not hold the restart back
echo FAIL >"$T/at/SEND"
: >"$T/syslog"
sms_cmd "$ADMIN" REBOOT
lw_expect_eq "$(reboots_n)" 2 "restarts when the reply fails"
lw_expect_eq "$(grep '^reboot' "$T/events" | tail -n 1)" "reboot note=yes sms=1" "second restart"
lw_expect_grep "$T/syslog" 'SMS control: reply not sent'
rm -f "$T/at/SEND"

# --- the seen list cannot be written (full flash): nothing runs, because after a restart the same
# command would run again; the pass that cannot save it drops the notes
mv_fail /lw-notify/seen
_r=$(reboots_n)
_n=$(sms_out)
sms_cmd "$ADMIN" REBOOT
lw_expect_eq "$(reboots_n)" "$_r" "restarts when the seen list cannot be saved"
lw_expect_eq "$(sms_out)" "$_n" "replies when the seen list cannot be saved"
sms_cmd "$ADMIN" STATUS
lw_expect_eq "$(sms_out)" "$_n" "replies to STATUS when the seen list cannot be saved"
mv_ok
echo ok
