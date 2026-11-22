# R65 to R68a, R72, R72b, R72d: every message the bot sends by itself in a tailscale image, with the
# layout's text: the link message (once, with the button and no preview), the refusal, the added message
# with and without another name, with the route pending and approved, with key expiry off, the route
# message, the expiry warning (a date under 14 days away, with and without a synced clock), the expired
# message with a new link, and the added message again after a new sign-in. The stand-in service
# (stubs/lw-tailscale) says what is due; when it is due is slice B's business, how it reads is here.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup ''
ts_on
ts_state not_added

ADMIN='login.tailscale.com/admin/machines'

# --- fresh state: the link message, once, with the button and no preview card (R65, D140)
ts_due link
pass
expect_sent 1
lw_expect_eq "$(sent_text 1)" '🔗 <b>Add this router to Tailscale</b>
Sign in with the link to reach the router from your own devices. No account yet? Signing in makes a free one.
https://login.tailscale.com/a/LINK0001
Only for the person who manages this router: whoever signs in first gets access.
Not working? Send /tailscale for a new link.' "link message"
lw_expect_eq "$(button_data 1 1)" ts:link "callback of the button"
lw_expect_eq "$(markup_of 1 | jsonfilter -e '@.inline_keyboard[0][0].text')" '🔗 New link' "button label"
lw_expect_eq "$(markup_of 1 | jsonfilter -e '@.inline_keyboard[0][0].url')" '' "a callback button, not a URL button"
lw_expect_eq "$(preview_of 1)" '{"is_disabled":true}' "link preview of the link message"
lw_expect_eq "$(ts_marked)" link "events marked"
# a restart before anyone signs in: the service has marked it, so nothing comes again (R65, R72b)
reboot_sim
passes 3
expect_sent 1
lw_expect_eq "$(ts_marked)" link "events marked after the restart"
lw_expect_eq "$(find /etc/lw-notify/queue -type f 2>/dev/null | wc -l | tr -d ' ')" 0 "queue after the send"

# --- the key of the profile was refused: the refusal message carries the link, no button (R66a)
ts_due refused
pass
expect_sent 2
lw_expect_eq "$(sent_text 2)" '⚠️ <b>The Tailscale key in the profile did not work</b> (expired or already used).
Add the router with this link instead:
https://login.tailscale.com/a/LINK0002
Only for the person who manages this router: whoever signs in first gets access.' "refusal message"
lw_expect_eq "$(markup_of 2)" '' "buttons of the refusal message"
lw_expect_eq "$(preview_of 2)" '{"is_disabled":true}' "link preview of the refusal message"

# --- added, as lte-router, the expiry step with its date (R65b, D143)
ts_state added
ts_due added
pass
expect_sent 3
lw_expect_eq "$(sent_text 3)" "✅ <b>Added to Tailscale as lte-router</b>
Account: jan@example.com
On a laptop or phone, install the Tailscale app, sign in with the same account and open https://lte-router.
❗ One more step: on $ADMIN, in the ⋯ menu of lte-router, choose Disable key expiry. Otherwise you must sign in again on 21 May." "added message"
lw_expect_eq "$(preview_of 3)" '{"is_disabled":true}' "link preview of the added message"
lw_expect_eq "$(ts_marked | tail -n 1)" added "marked"

# --- the same name in capitals is no other name (R65c); a route that is not offered gets no line
ts_state added name=LTE-Router route=pending
ts_due added
pass
expect_sent 4
case $(sent_text 4) in
    *'was taken'* | *'approve it'*) lw_fail "added message with the same name: $(sent_text 4)" ;;
esac
expect_last 'Added to Tailscale as LTE-Router'

# --- another name, and the route offered but not approved (R65c); the old entry first, then the route
ts_lan 1 192.168.5.0/24
ts_state added name=lte-router-1 route=pending
ts_due added
pass
expect_sent 5
lw_expect_eq "$(sent_text 5)" "✅ <b>Added to Tailscale as lte-router-1</b>
Account: jan@example.com
On a laptop or phone, install the Tailscale app, sign in with the same account and open https://lte-router-1.
❗ One more step: on $ADMIN, in the ⋯ menu of lte-router-1, choose Disable key expiry. Otherwise you must sign in again on 21 May.
The name lte-router was taken, probably by this router before a reset. Remove the old one there (⋯ &gt; Remove), then rename this one (⋯ &gt; Edit machine name).
To reach devices on the router's network (192.168.5.0/24), approve it there: ⋯ &gt; Edit route settings." "added message with an old entry and a route waiting"
# the route is offered and approved already: no line for it
ts_state added name=lte-router route=approved
ts_due added
pass
case $(last_text) in *'approve it'*) lw_fail "route line for an approved route: $(last_text)" ;; esac

# --- key expiry is off for the router: no step and no date; the places of the other lines then say
# where the admin page is (R65b)
ts_state added name=lte-router-1 route=pending expiry_off=1 expiry=
ts_due added
pass
lw_expect_eq "$(last_text)" "✅ <b>Added to Tailscale as lte-router-1</b>
Account: jan@example.com
On a laptop or phone, install the Tailscale app, sign in with the same account and open https://lte-router-1.
The name lte-router was taken, probably by this router before a reset. Remove the old one on $ADMIN (⋯ &gt; Remove), then rename this one (⋯ &gt; Edit machine name).
To reach devices on the router's network (192.168.5.0/24), approve it on $ADMIN: ⋯ &gt; Edit route settings." "added message, key expiry off"
# the account has no name yet: no account line
ts_state added account=
ts_due added
pass
case $(last_text) in *'Account:'*) lw_fail "account line without an account: $(last_text)" ;; esac

# --- the route is approved: the route message (R67a)
n=$(sent)
ts_state added route=approved
ts_due route
pass
expect_sent $((n + 1))
lw_expect_eq "$(last_text)" '✅ Tailscale: devices on 192.168.5.0/24 are reachable now.' "route message"

# --- the expiry warning, 10 days before the end: the date of the state (R68, D160); the text does not
# depend on the clock, whether the warning is due does (the service decides)
exp=$(($(cat "$T/wall") + 864000))
ts_state added "expiry=$exp"
for ntp in on off; do
    ntp_$ntp
    n=$(sent)
    ts_due expiry_warning
    pass
    expect_sent $((n + 1))
    lw_expect_eq "$(last_text)" "⚠️ <b>Tailscale sign-in of this router ends 17 Nov</b>
To keep access, on $ADMIN choose Disable key expiry in the ⋯ menu of lte-router." "expiry warning, clock $ntp"
done
ntp_on

# --- the sign-in ended, or the router was removed: the expired message with a new link (R68a)
n=$(sent)
ts_state ended
ts_due expired
pass
expect_sent $((n + 1))
lw_expect_eq "$(last_text)" '🔴 <b>This router is no longer in Tailscale</b> (the sign-in ended, or it was removed)
Sign in again to get access back:
https://login.tailscale.com/a/LINK0003
Only for the person who manages this router: whoever signs in first gets access.' "expired message"
lw_expect_eq "$(markup_of "$(sent)")" '' "buttons of the expired message"

# --- the owner signs in again: the added message once more, then the route, in the order of `due`
# (R72b, D151, D159); the warning of the new date comes later
n=$(sent)
ts_state added route=approved
ts_due added route
pass
expect_sent $((n + 2))
case $(sent_text $((n + 1))) in '✅ <b>Added to Tailscale as lte-router</b>'*) ;; *) lw_fail "added again: $(sent_text $((n + 1)))" ;; esac
lw_expect_eq "$(last_text)" '✅ Tailscale: devices on 192.168.5.0/24 are reachable now.' "route message again"
pass
expect_sent $((n + 2))

# --- one message per event, nothing the service did not report, nothing without the HTML rules
lw_expect_eq "$(ts_marked | tr '\n' ' ')" \
    'link refused added added added added added added route expiry_warning expiry_warning expired added route ' \
    "events marked in all"
lw_expect_eq "$(cat "$T/ts/due")" '' "events still due"
no_link_logged
expect_all_html
echo ok
