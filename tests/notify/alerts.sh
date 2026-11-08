# R40c: one message when the router goes to the EDGE backup, once per outage even when EDGE is
# entered again after a ladder reboot; none with the switch off. R37, R37a, R37c: /alerts shows the
# automatic messages, "/alerts 2g off|on" switches the 2G one and confirms, the switch survives a
# reboot, a new flash restores "on", the flash is written only on a change, other chats get nothing.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup 7.50
passes 2

rec_state() {
    printf 'cycles=%s\nreboots=%s\nclass=hang\npassive=%s\nuptime=900\n' "$1" "$2" "${3:-0}" \
        >/etc/wwan-recover.state
}
flash_state() {
    find /etc /root -type f -exec ls -li {} + | sort
    find /etc /root -type f -exec md5sum {} + | sort
}
# restart: the router reboots (RAM gone, clock unsynced until ntpd is back) and the service
# makes its first contact with the bot
restart() {
    lw_reboot_sim 90
    ntp_on
    passes 2
}
TWOG="🟠 Internet slow: switched to 2G backup
Messages and email OK, video and calls no.
4G down since today 14:20, the router keeps trying to bring it back.
(/alerts 2g off turns this message off)"

# the list, on by default; "Low balance" follows the threshold in the profile
tg_push "$TG_CHAT" /alerts
pass
lw_expect_eq "$(last_text)" "🔔 Automatic messages
New SMS: on · Low balance: on · Internet back: on · 2G backup: on" "/alerts"
tg_push "$TG_CHAT" /help
pass
expect_last '/alerts – automatic messages, on or off'

# the R40c scenario: on, EDGE entered twice in one outage -> one 2G message, one Internet back
wall_set '2026-11-07 14:20'
rec_state 1 0
pass
wall_set '2026-11-07 14:25'
rec_state 2 0
pass
n=$(sent)
: >/tmp/lw-edge
pass
lw_expect_eq "$(sent)" $((n + 1)) "messages on entering EDGE"
lw_expect_eq "$(last_text)" "$TWOG" "2G message"
lw_expect_grep /etc/lw-notify/outage '^edge=1'
passes 3
lw_expect_eq "$(sent)" $((n + 1)) "messages while on EDGE"
# a ladder reboot, EDGE again in the same outage
wall_set '2026-11-07 14:40'
rec_state 6 1
restart
: >/tmp/lw-edge
passes 2
lw_expect_eq "$(sent)" $((n + 1)) "messages on the second EDGE entry"
wall_set '2026-11-07 15:10'
rec_state 12 2
restart
: >/tmp/lw-edge
passes 2
lw_expect_eq "$(sent)" $((n + 1)) "messages on the third EDGE entry"
# LTE is back
wall_set '2026-11-07 15:20'
rm -f /etc/wwan-recover.state /tmp/lw-edge
pass
lw_expect_eq "$(sent)" $((n + 2)) "messages when LTE is back"
lw_expect_eq "$(last_text)" "🟢 Internet back after 1 h 00 min
Down since today 14:20, fixed by 2 restarts." "Internet back"

# the switch: off is confirmed, kept in a file, and written only once
tg_push "$TG_CHAT" '/alerts 2g off'
pass
lw_expect_eq "$(last_text)" "🔔 2G backup message is now off.
🔔 Automatic messages
New SMS: on · Low balance: on · Internet back: on · 2G backup: off" "off confirmation"
[ -e /etc/lw-notify/no-2g ] || lw_fail "the off switch left no file"
before=$(flash_state)
tg_push "$TG_CHAT" '/alerts@TestBot 2G OFF'
tg_push "$TG_CHAT" '/alerts 2g'
tg_push "$TG_CHAT" '/alerts everything'
pass
lw_expect_eq "$(flash_state)" "$before" "flash for an unchanged switch"
lw_expect_eq "$(sent_text "$(sent)" | sed -n 2p)" "New SMS: on · Low balance: on · Internet back: on · 2G backup: off" \
    "list with the switch off"

# survives a reboot; the 2G message stays away, Internet back does not
restart
tg_push "$TG_CHAT" /alerts
pass
expect_last '2G backup: off'
wall_set '2026-11-08 14:20'
rec_state 1 0
pass
rec_state 2 0
pass
n=$(sent)
: >/tmp/lw-edge
passes 2
lw_expect_eq "$(sent)" "$n" "2G message with the switch off"
wall_set '2026-11-08 14:50'
rm -f /etc/wwan-recover.state /tmp/lw-edge
pass
lw_expect_eq "$(sent)" $((n + 1)) "messages when LTE is back (switch off)"
expect_last '🟢 Internet back after 30 min'

# other chats get nothing and change nothing; the same command from the group works
n=$(sent)
tg_push "$TG_OTHER" '/alerts 2g on'
tg_push "$TG_OTHER" /alerts
pass
lw_expect_eq "$(sent)" "$n" "answers to a foreign chat"
[ -e /etc/lw-notify/no-2g ] || lw_fail "a foreign chat switched the message on"
tg_push "$TG_CHAT" '/alerts 2g on'
pass
lw_expect_eq "$(last_text | head -n 1)" "🔔 2G backup message is now on." "on confirmation"
[ ! -e /etc/lw-notify/no-2g ] || lw_fail "the on switch left the file"
before=$(flash_state)
tg_push "$TG_CHAT" '/alerts 2g on'
pass
lw_expect_eq "$(flash_state)" "$before" "flash for on when already on"
# no threshold in the profile: no low-balance warnings, and the list says so
uci -q delete lonewrt.notify.low_balance
uci -q commit lonewrt
tg_push "$TG_CHAT" /alerts
pass
expect_last 'Low balance: off'

# a new flash restores "on" (the overlay is empty)
tg_push "$TG_CHAT" '/alerts 2g off'
pass
[ -e /etc/lw-notify/no-2g ] || lw_fail "off not set"
rm -r -f /etc/lw-notify
restart
tg_push "$TG_CHAT" /alerts
pass
expect_last '2G backup: on'

# R37a: the switch is the only state the commands change; no uci write, no AT setting
lw_expect_no_grep "$T/at-calls" 'AT+[A-Z]*='
echo ok
