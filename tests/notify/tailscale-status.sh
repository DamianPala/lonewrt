# R69, R69c, R39c: /status of a tailscale image has one Tailscale line, the name and no address, after
# the data of the month and before the start line; /help has the /tailscale line after the buttons and
# the keyboard has its tenth button (D162, tests/notify/tailscale-keyboard.sh); an image without
# Tailscale has neither (R37).
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup ''
lw_uptime_set 1140
lw_net up down
sig_line -86dBm 4.6dB
passes 2

# status: ask /status, return the answer
status() {
    tg_push "$TG_CHAT" /status
    pass
    last_text
}
# tsline TEXT: the lines of TEXT between the data line and the start line (what R69 puts there)
tsline() {
    printf '%s\n' "$1" | sed -n '/^📊 Data this month/,/^⏱ Up/p' | sed '1d; $d'
}

# --- an image without Tailscale: no line, no help line
lw_expect_eq "$(tsline "$(status)")" "" "Tailscale line in an image without Tailscale"
case $(status) in *Tailscale*) lw_fail "Tailscale in /status without it" ;; esac
tg_push "$TG_CHAT" /help
pass
case $(last_text) in *tailscale*) lw_fail "help of an image without Tailscale: $(last_text)" ;; esac

# --- a tailscale image: the line after the data of the month (R69, R39c)
ts_on
for want in \
    'not_added|🔒 Tailscale: not added yet (/tailscale)' \
    'ended|🔒 Tailscale: sign-in ended (/tailscale)' \
    'added|🔒 Tailscale: on as lte-router' \
    'starting|🔒 Tailscale: starting' \
    'not_running|🔒 Tailscale: not running'; do
    ts_state "${want%%|*}"
    lw_expect_eq "$(tsline "$(status)")" "${want#*|}" "Tailscale line, ${want%%|*}"
done
ts_down
lw_expect_eq "$(tsline "$(status)")" '🔒 Tailscale: not running' "Tailscale line, no state file"
# the name only: no address, no account
ts_state added
case $(status) in
    *100.101.102.103* | *jan@example.com*) lw_fail "address or account in /status: $(last_text)" ;;
esac
# the name is the service's, with a hostile one made harmless (R37g)
ts_state added 'name=<b>x&y'
lw_expect_eq "$(tsline "$(status)")" '🔒 Tailscale: on as &lt;b&gt;x&amp;y' "name with markup in /status"
# the rest of /status stays as it was: the verdict first, the Tech quote last
ts_state added
case $(status) in
    '🟢 <b>Internet works</b>'*'Tech: '*'</blockquote>') ;;
    *) lw_fail "/status of a tailscale image: $(last_text)" ;;
esac
# --- /help: the line after the buttons, before the footer (R69c); the keyboard has 10 buttons (D162)
tg_push "$TG_CHAT" /help
pass
lw_expect_eq "$(last_text)" '❓ <b>What the buttons do</b>
🟢 <b>Status</b> – is the internet OK
📶 <b>Wi-Fi</b> – name, password and a QR code for guests
📱 <b>Devices</b> – who is connected, data this month, names
⚡ <b>Speed</b> – measure the speed (~60 s)
💶 <b>Balance</b> – ask Telekom (~1 min)
✉️ <b>SMS</b> – newest SMS (/sms 10 for more)
🔔 <b>Alerts</b> – automatic messages, on or off
🔄 <b>Reboot</b> – restart the router (asks first)
/tailscale – remote access from your own devices

The bot also posts by itself: new SMS, internet back, 2G backup.' "help of a tailscale image"
lw_expect_eq "$(markup_of "$(sent)" | jsonfilter -e '@.keyboard[*][*].text' | wc -l | tr -d ' ')" 10 \
    "buttons of the keyboard"
case $(markup_of "$(sent)") in *'🔒 Tailscale'*) ;; *) lw_fail "no Tailscale button on the keyboard" ;; esac
# an unknown command gets the same help
tg_push "$TG_CHAT" /nonsense
pass
case $(last_text) in *'/tailscale – remote access'*) ;; *) lw_fail "unknown command: $(last_text)" ;; esac
expect_all_html
echo ok
