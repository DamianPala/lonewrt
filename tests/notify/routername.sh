# R48: every SMS reply starts with the router name of the profile (uci lonewrt.notify.router_name), and a
# text that starts with that name is never a command (two routers must not answer each other), not
# with the default name "Home router" of the test setup. R46a: with a 20-character name every reply
# still fits one SMS of 160 ASCII characters, in every state, without a word cut in two: a reply that does not fit loses
# whole optional parts or takes its short form.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
export LW_SMSCTL_MAX=1000
notify_setup 7.50
ADMIN=+48000000001
admins_set "$ADMIN"
LONG='Abcdefghij-Klmnopqr1'
[ "${#LONG}" = 20 ] || lw_fail "the long name is not 20 characters"
passes 2

name_set() {
    uci -q set lonewrt.notify.router_name="$1"
    uci -q commit lonewrt
}
rec_state() {
    printf 'cycles=%s\nreboots=%s\nclass=%s\npassive=%s\nuptime=900\n' "$1" "$2" "$3" "${4:-0}" \
        >/etc/wwan-recover.state
}
# reply: a command from the admin, the text of the newest reply
reply() {
    sms_cmd "$ADMIN" "$1" "${2-11/07/26 11:21:00}"
    sms_body "$(sms_out)"
}

# --- the name starts every reply: OK, down, REBOOT and its refusals, HELP, a text of no command
name_set 'Home 2-b'
lw_net up down
sig_line -86dBm 4.6dB
sms_in 0 1466 '11/07/26 11:05:00' 'Imate: 0.31 do 05.01.; '
passes 2
case $(reply status) in 'Home 2-b: internet OK (4G+), signal fair. On since '*) ;; *) lw_fail "OK: $(sms_body "$(sms_out)")" ;; esac
lw_expect_eq "$(reply help)" "Home 2-b commands: status, reboot" "HELP"
lw_expect_eq "$(reply 'what is this')" "Home 2-b commands: status, reboot" "other text"
lw_net down down
rec_state 7 2 hang
case $(reply status) in 'Home 2-b: internet DOWN since '*'. Self-repair step 3 of 6, cause: modem not responding. 2G backup: off.'*) ;; *) lw_fail "down: $(sms_body "$(sms_out)")" ;; esac
rm -f /etc/wwan-recover.state
lw_net up down
lw_expect_eq "$(reply REBOOT "$(smsc_ts -3600)")" \
    "Home 2-b: reboot not done, the SMS is older than 10 min or has no time. Send it again." "REBOOT, too old"
sms_put "$ADMIN" REBOOT
rm -f /tmp/lw-notify/sc_scanned
n=$(sms_out)
passes 2
lw_expect_eq "$(sms_body $((n + 1)))" \
    "Home 2-b: reboot not done, it was already waiting when the router started. Send it again." "REBOOT, from before the start"
uci -q set lonewrt.notify.sms_reboot_max_day=1
uci -q commit lonewrt
lw_expect_eq "$(reply REBOOT "$(smsc_ts 0)")" "Home 2-b: restarting now, back in about 2 min." "REBOOT"
lw_expect_eq "$(reply REBOOT "$(smsc_ts 0)")" \
    "Home 2-b: reboot not done, 1 restarts by SMS in the last day. Try again later." "REBOOT, over the limit"

# --- the loop guard follows the name
n=$(sms_out)
sent0=$(sent)
sms_cmd "$ADMIN" 'Home 2-b: internet OK, signal good.'
sms_cmd "$ADMIN" 'HOME 2-B commands: STATUS, REBOOT'
sms_cmd "$ADMIN" 'home 2-bx'
lw_expect_eq "$(sms_out)" "$n" "replies to texts that start with the name"
lw_expect_eq "$(sent)" $((sent0 + 3)) "the texts still reach the chat"
# the default test name is not special once the profile names the router: a text with it that
# is no reply shape gets the help (the reply shapes of other routers come next)
sms_cmd "$ADMIN" 'Home router: hello'
lw_expect_eq "$(sms_out)" $((n + 1)) "reply to the old prefix"
lw_expect_eq "$(sms_body "$(sms_out)")" "Home 2-b commands: status, reboot" "text of the old prefix"
# a reply of a router with another name has the same fixed shapes: no answer, no restart
m=$(sms_out)
r0=$(reboots_n)
sent0=$(sent)
for t in 'Villa 2: internet OK (4G+), signal fair. On since 7 Nov 11:01.' \
    'villa 2: internet DOWN since 11:01 (5 min). Self-repair step 3 of 6, cause: modem not responding.' \
    'Villa 2: 4G DOWN since 11:01 (5 min), internet slow. Self-repair step 1 of 6.' \
    'Villa 2: internet DOWN, the router is checking. Self-repair starts if it lasts.' \
    'Villa 2: reboot not done, the SMS is older than 10 min or has no time. Send it again.' \
    'Villa 2: reboot not done, 5 restarts by SMS in the last day. Try again later.' \
    'Villa 2: restarting now, back in about 2 min.' \
    'Villa 2 commands: status, reboot' \
    'Home router: internet OK, signal good.' \
    "$LONG: internet OK, signal good."; do
    sms_cmd "$ADMIN" "$t"
done
lw_expect_eq "$(sms_out)" "$m" "replies to the replies of another router"
lw_expect_eq "$(reboots_n)" "$r0" "restarts by the replies of another router"
lw_expect_eq "$(sent)" $((sent0 + 10)) "the replies of another router still reach the chat"
# human texts of the same shape of words are not replies
sms_cmd "$ADMIN" 'Hi: status'
lw_expect_eq "$(sms_out)" $((m + 1)) "reply to Hi: status"
lw_expect_eq "$(sms_body "$(sms_out)")" "Home 2-b commands: status, reboot" "text of Hi: status"
sms_cmd "$ADMIN" 'Villa 2: please reboot'
lw_expect_eq "$(sms_out)" $((m + 2)) "reply to a human text with a name"
sms_cmd "$ADMIN" 'Abcdefghij-Klmnopqr1x: internet OK'
lw_expect_eq "$(sms_out)" $((m + 3)) "reply to a prefix longer than any name"
sms_cmd "$ADMIN" STATUS
lw_expect_eq "$(sms_out)" $((m + 4)) "STATUS next to the other routers' replies"
# the shapes above are the real ones: collect the replies a router named Villa 2 really gives (OK,
# down, HELP, the REBOOT refusals) and feed them to Home 2-b
name_set 'Villa 2'
lw_net up down
rm -f /etc/wwan-recover.state
real=$(reply status)
lw_net down down
rec_state 7 2 hang
real="$real
$(reply status)
$(reply help)
$(reply REBOOT "$(smsc_ts -3600)")
$(reply REBOOT "$(smsc_ts 0)")"
rm -f /etc/wwan-recover.state
lw_net up down
name_set 'Home 2-b'
m=$(sms_out)
r0=$(reboots_n)
lw_expect_eq "$(printf '%s\n' "$real" | wc -l | tr -d ' ')" 5 "real replies collected"
oldifs=$IFS
IFS='
'
for t in $real; do
    case $t in 'Villa 2'*) ;; *) lw_fail "not a reply of Villa 2: $t" ;; esac
    sms_cmd "$ADMIN" "$t"
done
IFS=$oldifs
lw_expect_eq "$(sms_out)" "$m" "replies to the real replies of another router"
lw_expect_eq "$(reboots_n)" "$r0" "restarts by the real replies of another router"
# the count below counts from here: one reply already sent after n
n=$(($(sms_out) - 1))
# a command is still a command when the name is a command word
name_set Status
sms_cmd "$ADMIN" status
case $(sms_body "$(sms_out)") in 'Status: internet OK'*) ;; *) lw_fail "name Status: $(sms_body "$(sms_out)")" ;; esac
lw_expect_eq "$(sms_out)" $((n + 2)) "a command with the name Status"
sms_cmd "$ADMIN" 'Status: internet OK, signal good.'
lw_expect_eq "$(sms_out)" $((n + 2)) "own reply as a text, name Status"
rm -f "$T/sms-sent"

# --- 160 characters with a 20-character name: the replies under the short name and under the long
# one, for the states of smsstatus.sh and the REBOOT texts. A reply is never longer than 160, ends
# with a full stop, and where the short-name reply with the long name still fits it is that very
# text (only the name differs)
i=0
check() {
    # check LABEL: the reply to STATUS now, under both names
    i=$((i + 1))
    name_set 'Home router'
    a=$(reply status)
    name_set "$LONG"
    b=$(reply status)
    [ "${#b}" -le 160 ] || lw_fail "$1: ${#b} characters: $b"
    case $b in "$LONG: "*) ;; *) lw_fail "$1: no name at the start: $b" ;; esac
    case $b in *.) ;; *) lw_fail "$1: does not end with a full stop (cut?): $b" ;; esac
    [ -z "$(printf '%s' "$b" | tr -d '\040-\176')" ] || lw_fail "$1: not ASCII: $b"
    full="$LONG: ${a#Home router: }"
    if [ "${#full}" -le 160 ]; then
        lw_expect_eq "$b" "$full" "$1: same text under the long name"
    fi
    longest=$((${longest:-0} > ${#b} ? ${longest:-0} : ${#b}))
}
longest=0
lw_net down down
wall_set '2026-11-07 14:52'
for cls in hang account sim unknown; do
    rec_state 7 1 "$cls"
    check "down, $cls"
    rec_state 7 6 "$cls" 1
    check "limit, $cls"
done
rec_state 7 1 hang
sig_line -86dBm 4.6dB
check "down, signal"
rm -f /etc/wwan-recover.state
check "down, nothing counted"
# the longest times: a month of failure, the limit reached, the 2G backup, a balance
: >/tmp/lw-edge
lw_net down up
rec_state 9000 5 account 1
check "month, 2G, account"
rec_state 9000 5 hang 1
check "month, 2G, hang"
sms_in 50 1466 '11/07/26 14:00:00' 'Imate: 1234.56 do 05.01.; '
passes 2
check "month, 2G, hang, balance"
rm -f /tmp/lw-edge /etc/wwan-recover.state
lw_net up down
check "OK with signal and balance"
ntp_off
check "OK without a clock"
ntp_on
rec_state 9000 5 hang 1
check "month, hang, no 2G"
echo "longest status reply: $longest"
[ "$longest" -le 160 ] || lw_fail "a reply of $longest characters"

# the REBOOT texts and HELP with the long name
name_set "$LONG"
for t in "$(reply HELP)" "$(reply REBOOT "$(smsc_ts -3600)")"; do
    [ "${#t}" -le 160 ] || lw_fail "REBOOT or HELP text of ${#t} characters: $t"
done
uci -q set lonewrt.notify.sms_reboot_max_age=9999
uci -q set lonewrt.notify.sms_reboot_max_day=9999
uci -q commit lonewrt
t=$(reply REBOOT "$(smsc_ts -3600000)")
[ "${#t}" -le 160 ] || lw_fail "REBOOT age text of ${#t} characters: $t"
sms_put "$ADMIN" REBOOT
rm -f /tmp/lw-notify/sc_scanned
passes 2
t=$(sms_body "$(sms_out)")
[ "${#t}" -le 160 ] || lw_fail "REBOOT start text of ${#t} characters: $t"
echo ok
