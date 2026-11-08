# R40b: with no RTC the clock is right only after ntpd synced it (OpenWrt's 25-dnsmasqsec file,
# created on the first ntpd "stratum" event). An outage that began before that gets "~" in front
# of its start and length; the length then comes from the repair cycles, not from the clock that
# jumped. An outage whose start the service never saw is treated the same way.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup ''
passes 2

rec_state() {
    printf 'cycles=%s\nreboots=%s\nclass=hang\npassive=%s\nuptime=900\n' "$1" "$2" "${3:-0}" \
        >/etc/wwan-recover.state
}

# the router boots without internet and without ntpd's sync: the clock shows the fixtime date
lw_reboot_sim 30
ntp_off
wall_set '2026-11-05 03:00'
passes 2
rec_state 1 0
pass
rec_state 2 0
pass
rec_state 3 0
pass
lw_expect_grep /etc/lw-notify/outage '^ntp=0'
# /status while it goes on, ntpd back: the start counted back from the cycles, with "~"
wall_set '2026-11-07 09:15'
ntp_on
tg_push "$TG_CHAT" /status
pass
lw_expect_eq "$(last_text | grep '^🔧')" \
    "🔧 Last outage: since ~today 09:00, still going, 0 restarts so far" "ongoing, start before NTP"
# LTE is back and ntpd steps the clock to the real time in the same minute
wall_set '2026-11-07 09:15'
ntp_on
rm -f /etc/wwan-recover.state
pass
lw_expect_eq "$(last_text)" "🟢 Internet back after ~15 min
Down since ~today 09:00, fixed without a restart." "outage before NTP"
tg_push "$TG_CHAT" /status
pass
lw_expect_eq "$(last_text | grep '^🔧')" "🔧 Last outage: ~today 09:00, ~15 min, fixed without a restart" \
    "Last outage before NTP"

# the clock is right at the start but gone at the end (a restart cleared it, ntpd is not back
# yet): the start is exact, the length is counted from the cycles
wall_set '2026-11-07 14:20'
ntp_on
rec_state 1 0
pass
rec_state 2 0
pass
rec_state 3 1
lw_reboot_sim 90
ntp_off
wall_set '2026-11-05 03:00'
passes 3
rm -f /etc/wwan-recover.state
pass
lw_expect_eq "$(last_text)" "🟢 Internet back after ~15 min
Down since 7 Nov 14:20, fixed by 1 restart." "no NTP at the end"

# neither at the start nor at the end: the date is the clock's own, with "~", never "today"
rec_state 1 0
pass
rec_state 2 0
pass
rm -f /etc/wwan-recover.state
pass
lw_expect_eq "$(last_text)" "🟢 Internet back after ~10 min
Down since ~5 Nov 03:00, fixed without a restart." "no NTP at all"

# an outage the service did not see begin (no record, RAM gone) is estimated from its cycles
ntp_on
wall_set '2026-11-07 18:00'
rec_state 4 1
lw_reboot_sim 90
ntp_on
passes 2
lw_expect_grep /etc/lw-notify/outage '^ntp=0'
wall_set '2026-11-07 18:30'
rm -f /etc/wwan-recover.state
pass
lw_expect_eq "$(last_text)" "🟢 Internet back after ~20 min
Down since ~today 18:10, fixed by 1 restart." "start not seen"
echo ok
