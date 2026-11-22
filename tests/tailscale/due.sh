# R65, R65b, R67a, R68, R68a, R72b, R72c, D151, D159, D160: the one-time messages the bot is owed
# (`lw-tailscale due`), and that each comes once per occasion (`lw-tailscale mark`), across restarts.
# shellcheck source=tests/tailscale/ts.inc
. /fw/tests/tailscale/ts.inc
ts_setup
DAY=86400

rc=0
lw-tailscale mark bogus 2>/dev/null || rc=$?
lw_expect_eq "$rc" 1 "mark of an unknown event"
lw_expect_eq "$(ts_due)" "" "due without a state file"

# the link message: once per flash that does not keep settings or button reset (R65, R72b, R72c)
ts_backend NeedsLogin
ts_once
lw_expect_eq "$(ts_due)" link "a fresh router"
lw-tailscale mark link
lw_expect_eq "$(ts_due)" "" "after the link message went"
ts_reboot
ts_once
lw_expect_eq "$(ts_due)" "" "after a restart (R72c)"
rm -rf /etc/tailscale
mkdir -p /etc/tailscale
ts_reboot
ts_once
lw_expect_eq "$(ts_due)" link "after a button reset"

# the added message, once per sign-in; far expiry, no route (R65b)
ts_added $((BASE + 100 * DAY))
ts_once
lw_expect_eq "$(ts_due)" added "an added router"
lw-tailscale mark added
lw_expect_eq "$(ts_due)" "" "after the added message went"
ts_reboot
ts_once
lw_expect_eq "$(ts_due)" "" "added, after a restart"

# a crash of the daemon is not an end of the sign-in, and the router is not added again after it
ts_down
ts_once
lw_expect_eq "$(ts_due)" "" "while the daemon is down"
ts_added $((BASE + 100 * DAY))
ts_once
lw_expect_eq "$(ts_due)" "" "after the daemon is back"

# the route message, once per sign-in (R67a, D159)
uci set lonewrt.tailscale.advertise_lan=1
uci commit lonewrt
ts_once
lw_expect_eq "$(ts_due)" "" "route offered but not approved"
echo 192.168.5.0/24 >"$D/routes"
ts_once
lw_expect_eq "$(ts_due)" route "route approved"
lw-tailscale mark route
lw_expect_eq "$(ts_due)" "" "after the route message went"

# the expiry warning (R68): 14 days before the date, once per date, never without NTP or with the
# date off
ts_added $((BASE + 20 * DAY))
echo 192.168.5.0/24 >"$D/routes"
ts_once
lw_expect_eq "$(ts_due)" "" "20 days before the end"
ts_wall $((BASE + 6 * DAY - 1))
ts_once
lw_expect_eq "$(ts_due)" "" "14 days and a second before the end"
ts_wall $((BASE + 6 * DAY))
rm -f "$T/ntp"
ts_once
lw_expect_eq "$(ts_due)" "" "14 days before the end without NTP"
: >"$T/ntp"
lw_expect_eq "$(ts_due)" expiry_warning "14 days before the end"
lw-tailscale mark expiry_warning
lw_expect_eq "$(ts_due)" "" "after the warning went"
ts_reboot
ts_once
lw_expect_eq "$(ts_due)" "" "the warning once per date, after a restart"
ts_wall $((BASE + 19 * DAY))
ts_once
lw_expect_eq "$(ts_due)" "" "the warning once per date, a week later"
# the date changes (key expiry moved in the admin page): a new warning
ts_added $((BASE + 30 * DAY))
ts_wall $((BASE + 17 * DAY))
ts_once
lw_expect_eq "$(ts_due)" expiry_warning "a new date, 13 days away"
lw-tailscale mark expiry_warning
# key expiry turned off: none
ts_added
ts_once
lw_expect_eq "$(ts_due)" "" "key expiry off"

# the sign-in ends (R68a): the expired message once per change
ts_backend NeedsLogin
ts_once
lw_expect_eq "$(ts_st state)" ended "state"
lw_expect_eq "$(ts_due)" expired "the sign-in ended"
lw-tailscale mark expired
lw_expect_eq "$(ts_due)" "" "after the expired message went"
ts_reboot
ts_once
lw_expect_eq "$(ts_due)" "" "ended, after a restart"
ts_down
ts_once
lw_expect_eq "$(ts_due)" "" "ended, daemon down"
ts_backend NeedsLogin
ts_once
lw_expect_eq "$(ts_due)" "" "ended, daemon back (no link message: R65 is for a fresh router)"

# signed in again (the owner used the link of the expired message): the added message and the route
# message come again, and the warning for the new date (R72b, D151, D159), also at once when the
# new date is under 14 days away (D160)
ts_added $((BASE + 17 * DAY + 5 * DAY))
echo 192.168.5.0/24 >"$D/routes"
ts_once
lw_expect_eq "$(ts_due)" "added route expiry_warning" "after a new sign-in"
lw-tailscale mark added
lw-tailscale mark route
lw-tailscale mark expiry_warning
lw_expect_eq "$(ts_due)" "" "after the messages of the new sign-in went"

# removed in the admin page and signed in again: the same cycle; and the expired message comes again
ts_backend NeedsLogin
ts_once
lw_expect_eq "$(ts_due)" expired "removed in the admin page"
lw-tailscale mark expired
ts_added
echo 192.168.5.0/24 >"$D/routes"
ts_once
lw_expect_eq "$(ts_due)" "added route" "signed in again after the removal"
lw-tailscale mark added
lw-tailscale mark route
lw_expect_eq "$(ts_due)" "" "all went"

# a flash that keeps settings keeps /etc/tailscale: nothing comes again (R72c)
ts_reboot
ts_once
lw_expect_eq "$(ts_due)" "" "after a restart with everything sent"

# starting is not a state to report on: nothing due, nothing lost
ts_backend Starting
ts_once
lw_expect_eq "$(ts_due)" "" "while starting"
ts_added
echo 192.168.5.0/24 >"$D/routes"
ts_once
lw_expect_eq "$(ts_due)" "" "added again after starting"
echo ok
