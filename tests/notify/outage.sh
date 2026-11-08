# R40, R40a: "Internet back" once per outage that lasted longer than one repair cycle, with the
# start, the length and the restarts; the record survives restarts of the router and shows in
# /status; a power cut without an outage, an outage of one cycle and a restart after the message
# give nothing; a message that cannot be sent waits in the queue. R34c: the record is written at
# the start and at the end only, and an idle outage writes nothing.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup ''
passes 2

# rec_state CYCLES REBOOTS [PASSIVE]: what wwan-recover keeps while a failure lasts
rec_state() {
    printf 'cycles=%s\nreboots=%s\nclass=hang\npassive=%s\nuptime=900\n' "$1" "$2" "${3:-0}" \
        >/etc/wwan-recover.state
}
# flash_state: every file under /etc and /root with its inode, size and content hash
flash_state() {
    find /etc /root -type f -exec ls -li {} + | sort
    find /etc /root -type f -exec md5sum {} + | sort
}

# a power cut with no outage: nothing, not now and not at the next start
lw_reboot_sim
ntp_on
passes 3
expect_sent 0
[ ! -e /etc/lw-notify/outage ] || lw_fail "outage record after a power cut"

# an outage of one cycle: the start is only noted in RAM, nothing is written, no message
wall_set '2026-11-07 09:00'
rec_state 1 0
pass
wall_set '2026-11-07 09:05'
rm -f /etc/wwan-recover.state
passes 2
expect_sent 0
[ ! -e /etc/lw-notify/outage ] || lw_fail "outage record for a one-cycle outage"

# the R40 scenario: from 14:20, 12 min, one restart of the router
wall_set '2026-11-07 14:20'
rec_state 1 0
pass
[ ! -e /etc/lw-notify/outage ] || lw_fail "record written at the first cycle"
wall_set '2026-11-07 14:25'
rec_state 2 0
pass
lw_expect_grep /etc/lw-notify/outage '^state=open'
wall_set '2026-11-07 14:30'
rec_state 3 0
pass
expect_sent 0
# R34c: an outage that goes on writes nothing to flash or syslog
before=$(flash_state)
: >"$T/syslog"
passes 25
lw_expect_eq "$(flash_state)" "$before" "flash during an idle outage"
lw_expect_eq "$(cat "$T/syslog")" "" "syslog during an idle outage"
# the router restarts by self-repair: RAM and the clock go, the record stays
rec_state 3 1
lw_reboot_sim 90
wall_set '2026-11-07 14:31'
passes 3
expect_sent 0
lw_expect_grep /etc/lw-notify/outage '^state=open'
# LTE is back, ntpd synced again, the failure is over
wall_set '2026-11-07 14:32'
ntp_on
rm -f /etc/wwan-recover.state
pass
expect_sent 1
lw_expect_eq "$(last_text)" "🟢 Internet back after 12 min
Down since today 14:20, fixed by 1 restart." "Internet back"
lw_expect_grep /etc/lw-notify/outage '^state=closed'
# /status shows the outage (R40a)
tg_push "$TG_CHAT" /status
pass
lw_expect_eq "$(last_text | grep '^🔧')" "🔧 Last outage: today 14:20, 12 min, fixed by 1 restart" \
    "Last outage"
# the next day it was yesterday
wall_set '2026-11-08 09:00'
tg_push "$TG_CHAT" /status
pass
lw_expect_eq "$(last_text | grep '^🔧')" "🔧 Last outage: yesterday 14:20, 12 min, fixed by 1 restart" \
    "Last outage, next day"
# the record survives a restart, and a restart after the message gives nothing more
n=$(sent)
lw_reboot_sim
ntp_on
passes 4
lw_expect_eq "$(sent)" "$n" "messages after a restart that follows the message"
lw_expect_grep /etc/lw-notify/outage '^state=closed'
tg_push "$TG_CHAT" /status
pass
lw_expect_eq "$(last_text | grep '^🔧')" "🔧 Last outage: yesterday 14:20, 12 min, fixed by 1 restart" \
    "Last outage after a restart"
n=$(sent)

# restart counts: none, and three
wall_set '2026-11-08 10:00'
rec_state 1 0
pass
rec_state 2 0
pass
wall_set '2026-11-08 10:20'
rm -f /etc/wwan-recover.state
pass
expect_last "Internet back after 20 min
Down since today 10:00, fixed without a restart."
wall_set '2026-11-08 12:00'
rec_state 1 0
pass
rec_state 9 3
pass
wall_set '2026-11-08 13:05'
rm -f /etc/wwan-recover.state
pass
lw_expect_eq "$(last_text)" "🟢 Internet back after 1 h 05 min
Down since today 12:00, fixed by 3 restarts." "three restarts"
lw_expect_eq "$(sent)" $((n + 2)) "one message per outage"

# a failure still going while the person is asked to come: the line says so
wall_set '2026-11-08 15:00'
rec_state 1 0
pass
rec_state 12 2
pass
tg_push "$TG_CHAT" /status
pass
lw_expect_eq "$(last_text | grep '^🔧')" "🔧 Last outage: since today 15:00, still going, 2 restarts so far" \
    "outage going on"
rm -f /etc/wwan-recover.state
pass

# Telegram unreachable when the outage ends: the message waits on flash, survives a restart and
# goes out once
n=$(sent)
echo down >"$G/net"
wall_set '2026-11-08 16:00'
rec_state 1 0
pass
rec_state 2 0
pass
wall_set '2026-11-08 16:10'
rm -f /etc/wwan-recover.state
passes 3
lw_expect_eq "$(sent)" "$n" "sent while Telegram is down"
lw_expect_eq "$(find /etc/lw-notify/queue -type f | wc -l)" 1 "queued messages"
lw_reboot_sim
ntp_on
passes 2
echo up >"$G/net"
passes 2
lw_expect_eq "$(sent)" $((n + 1)) "sent once Telegram is back"
lw_expect_eq "$(last_text)" "🟢 Internet back after 10 min
Down since today 16:00, fixed without a restart." "queued message"
lw_reboot_sim
ntp_on
passes 4
lw_expect_eq "$(sent)" $((n + 1)) "sent again after a restart"
lw_expect_eq "$(find /etc/lw-notify/queue -type f | wc -l)" 0 "queue after the send"
no_orphans
echo ok
