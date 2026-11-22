# R46, R46a, R69a, R65e, R65f, D148: the SMS command `tailscale` of an admin number in a tailscale
# image: a reply with a link made now while the router is not added (a new one each time), with the
# name, the address, the account and the date once it is (the account drops out first at 160
# characters), with its state while Tailscale starts or is down; the help reply lists it; an image
# without Tailscale takes it for any other text; a reply in the shape of ours, from this router or
# another, gets no reply; no link in syslog even when the send fails; with no Telegram keys the
# command works and nothing of `due` is taken. All numbers and names are fake.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup ''
export LW_SMSCTL_MAX=100
ADMIN=+48000000001
admins_set "$ADMIN"
ts_on
ts_state not_added
passes 2
expect_sent 0

# reply_is N TEXT WHAT: the Nth reply is TEXT, one ASCII SMS of at most 160 characters (R46a)
reply_is() {
    lw_expect_eq "$(sms_out)" "$1" "replies so far, $3"
    lw_expect_eq "$(sms_to "$1")" "${ADMIN#+}" "number of the reply, $3"
    lw_expect_eq "$(sms_body "$1")" "$2" "$3"
    [ "$(sms_body "$1" | wc -c)" -le 161 ] || lw_fail "reply longer than 160, $3: $(sms_body "$1")"
    [ "$(sms_body "$1" | tr -d '\012\040-\176' | wc -c)" = 0 ] || lw_fail "reply not ASCII, $3"
}

# --- not added: the link, a new one every time (R69a, D148)
sms_cmd 48000000001 tailscale
reply_is 1 'Home router: Tailscale sign-in link, open soon: https://login.tailscale.com/a/LINK0001' "link reply"
sms_cmd +48000000001 '  TailScale  '
reply_is 2 'Home router: Tailscale sign-in link, open soon: https://login.tailscale.com/a/LINK0002' \
    "link reply, letter case and spaces"
# the command reaches the chat like any SMS (R46); the reply is no message of the chat
lw_expect_eq "$(sent)" 2 "chat messages"
expect_last 'TailScale'
lw_expect_eq "$(ts_marked)" '' "events the SMS took off the list"

# a link too long for the full text gets the short form, never a cut link (R46a)
long='https://login.tailscale.com/a/'$(printf 'k%.0s' $(seq 1 100))
printf '#!/bin/sh\necho %s\n' "$long" >/usr/sbin/lw-tailscale-long
chmod +x /usr/sbin/lw-tailscale-long
LW_TS_BIN=/usr/sbin/lw-tailscale-long
export LW_TS_BIN
sms_cmd +48000000001 tailscale
reply_is 3 "Home router: Tailscale link: $long" "link reply, short form"
unset LW_TS_BIN
rm -f /usr/sbin/lw-tailscale-long

# --- added: name, address, account, date (R69a)
ts_state added
sms_cmd +48000000001 tailscale
reply_is 4 'Home router: Tailscale on as lte-router 100.101.102.103, account jan@example.com, sign-in ends 21 May.' \
    "state reply"
ts_state added expiry_off=1 expiry=
sms_cmd +48000000001 tailscale
reply_is 5 'Home router: Tailscale on as lte-router 100.101.102.103, account jan@example.com, no expiry.' \
    "state reply, key expiry off"
# the account is the first part to go when the reply would not fit one SMS
acct=$(printf 'a%.0s' $(seq 1 90))@example.com
ts_state added "account=$acct"
sms_cmd +48000000001 tailscale
reply_is 6 'Home router: Tailscale on as lte-router 100.101.102.103, sign-in ends 21 May.' \
    "state reply, account left out"
# an address-less state and a name that needs cleaning: still one ASCII SMS
ts_state added ip= 'name=h<llo' account=
sms_cmd +48000000001 tailscale
reply_is 7 'Home router: Tailscale on as h<llo, sign-in ends 21 May.' "state reply without address and account"

# --- starting, not running, silent (R69a)
ts_state starting
sms_cmd +48000000001 tailscale
reply_is 8 'Home router: Tailscale is starting, try again in a few min.' "starting"
ts_state not_running
sms_cmd +48000000001 tailscale
reply_is 9 'Home router: Tailscale not running, try again in a few min.' "not running"
ts_down
sms_cmd +48000000001 tailscale
reply_is 10 'Home router: Tailscale not running, try again in a few min.' "no state file"
ts_state not_added
: >"$T/ts/hang"
t0=$(date +%s)
sms_cmd +48000000001 tailscale
[ "$(elapsed_since "$t0")" -le 14 ] || lw_fail "a hung service held the SMS reply for $(elapsed_since "$t0") s"
reply_is 11 'Home router: Tailscale is starting, try again in a few min.' "service that does not answer"
rm -f "$T/ts/hang"

# --- other numbers get nothing (R46)
sms_cmd +48000000099 tailscale
sms_cmd Telekom tailscale
lw_expect_eq "$(sms_out)" 11 "replies to numbers off the list"

# --- help lists it in a tailscale image only (R69a)
sms_cmd +48000000001 help
reply_is 12 'Home router commands: status, reboot, tailscale' "help of a tailscale image"
sms_cmd +48000000001 'tailscale please'
reply_is 13 'Home router commands: status, reboot, tailscale' "help for text around the word"

# --- the loop guard: our own reply, and the reply of a router with another name (R46)
for text in \
    'Home router: Tailscale on as lte-router 100.101.102.103, account jan@example.com, sign-in ends 21 May.' \
    'Home router: Tailscale not running, try again in a few min.' \
    'Other box: Tailscale on as lte-router 100.101.102.103, account jan@example.com, sign-in ends 21 May.' \
    'Other box: Tailscale sign-in link, open soon: https://login.tailscale.com/a/LINK9999' \
    'Other box: Tailscale not running, try again in a few min.' \
    'Other box commands: status, reboot, tailscale'; do
    sms_cmd +48000000001 "$text"
done
lw_expect_eq "$(sms_out)" 13 "replies to texts in the shape of a router reply"

# --- a failed send: the log has no link and nothing the tool printed (R65f)
ts_state not_added
: >"$T/syslog"
echo NOTSENT >"$T/at/SEND"
sms_cmd +48000000001 tailscale
passes 2
lw_expect_eq "$(sms_out)" 13 "replies recorded when the send fails"
lw_expect_eq "$(grep -c 'lw-notify: SMS control: reply not sent' "$T/syslog")" 1 "failed-send entries"
rm -f "$T/at/SEND"
no_link_logged
lw_expect_no_grep "$T/syslog.prio" 'login.tailscale.com'

# --- an image without Tailscale: `tailscale` is any other text, so it gets the help (R46)
rm -f /usr/sbin/lw-tailscale
sms_cmd +48000000001 tailscale
reply_is 14 'Home router commands: status, reboot' "tailscale in an image without it"

# --- no Telegram keys, SMS control alone (R46d): the command works, `due` is left alone (R65e)
ts_on
ts_state not_added
uci -q delete lonewrt.notify.token
uci -q delete lonewrt.notify.chat
uci -q commit lonewrt
n=$(sent)
ts_due link added
sms_cmd +48000000001 tailscale
lw_expect_eq "$(sms_out)" 15 "replies without Telegram"
lw_expect_eq "$(sms_body 15)" 'Home router: Tailscale sign-in link, open soon: https://login.tailscale.com/a/LINK0001' \
    "link reply without Telegram"
passes 3
lw_expect_eq "$(ts_marked)" '' "events taken off the list without a chat"
lw_expect_eq "$(sent)" "$n" "chat messages without Telegram keys"
no_link_logged
echo ok
