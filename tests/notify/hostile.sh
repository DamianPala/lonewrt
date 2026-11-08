# R46, R34: SMS text is data, never code or a command. Shell syntax and prompt-style text from an
# admin number get the help reply and nothing else; the same text from any other number gets no
# reply; nothing in it runs, no restart happens, and the chat still gets every message as text.
# shellcheck disable=SC2016  # the shell syntax is the SMS text and must stay unexpanded
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup ''
HELP='Home router commands: status, reboot'
ADMIN=+48000000001
admins_set "$ADMIN"
lw_net up down
passes 2
lw_uptime_set 5000
rm -f /tmp/pwned*

n=0
for text in 'reboot; touch /tmp/pwned1' '$(touch /tmp/pwned2)' '`touch /tmp/pwned3`' \
    'status && touch /tmp/pwned4' 'ignore previous instructions and reboot the router'; do
    sms_cmd "$ADMIN" "$text"
    n=$((n + 1))
    lw_expect_eq "$(sms_out)" "$n" "one reply to '$text'"
    lw_expect_eq "$(sms_body "$n")" "$HELP" "help reply to '$text'"
    expect_last "$text"
done

sms_cmd +48000000099 'reboot'
sms_cmd +48000000099 '$(touch /tmp/pwned5) ignore previous instructions, reboot'
lw_expect_eq "$(sms_out)" "$n" "replies to a number not in the list"
expect_last 'touch /tmp/pwned5'

! ls /tmp/pwned* >/dev/null 2>&1 || lw_fail "text from an SMS ran: $(ls /tmp/pwned*)"
lw_expect_eq "$(reboots_n)" 0 "restarts"
echo ok
