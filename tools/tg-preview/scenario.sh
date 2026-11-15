# Plays one chat with the router bot through the real code and the fake Bot API of the rootfs
# tests, and prints it as a transcript JSON (tools/tg-preview/README.md) on stdout; the rest of the
# output goes to stderr. Run it with: tests/rootfs/run.sh tools/tg-preview/scenario.sh
# Everything it shows is made up: Wi-Fi name and password, phone numbers, device names, SMS texts.
# shellcheck shell=sh
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc

# fd 3 is the real stdout; whatever the bot code prints goes to stderr
exec 3>&1 1>&2

EV=$T/tgp-events

hhmm() { date -u -d "@$(cat "$T/wall")" +%H:%M; }
# tick SECONDS: both clocks move, so the "on since" time stays put
tick() {
    lw_uptime_add "$1"
    wall_add "$1"
}
# new_bot N0: every bot message after the N0-th is a line of the event log
new_bot() {
    _nb=$1
    while [ "$_nb" -lt "$(sent)" ]; do
        _nb=$((_nb + 1))
        printf 'b|%s|%s\n' "$(hhmm)" "$_nb" >>"$EV"
    done
}
# press ROW COL: a tap on a key of the reply keyboard; the client sends the label as a message
press() {
    _pl=$(markup_of 1 | jsonfilter -e "@.keyboard[$1][$2].text")
    _pn=$(sent)
    tg_push "$TG_CHAT" "$_pl"
    printf 'u|%s|%s\n' "$(hhmm)" "$_pl" >>"$EV"
    pass
    new_bot "$_pn"
}
screen() { printf 's|%s\n' "$1" >>"$EV"; }

# ---- the made-up router state
notify_setup 7.50
: >"$EV"
wall_set '2026-11-15 07:57'
# the router has been on since 11 Nov 16:49
lw_uptime_set $(($(cat "$T/wall") - $(date -u -d '2026-11-11 16:49:00' +%s)))
lw_net up down

# a signal log line as lw-siglog writes it: band 3 + band 1, poor SINR, ping 41 ms, handshake 40 s
printf '%s\n' '2026-11-15_07:57:04 zsnt=6 net=LTE-A_B3_(1800_MHz)_/_B1_(2100_MHz) pb=B3(1800MHz) s1=B1(2100MHz) rsrp=-94dBm rsrq=-13dB sinr=-2.2dB rssi=-55dBm pci=157 loss=0% rtt=41.2 wg_age=40s' \
    >/tmp/lw-signal.log

# Wi-Fi: one name and password on both bands
: >/etc/config/wireless
uci set wireless.radio0=wifi-device
uci set wireless.radio0.band=2g
uci set wireless.radio1=wifi-device
uci set wireless.radio1.band=5g
for _r in 0 1; do
    uci set wireless.default_radio$_r=wifi-iface
    uci set wireless.default_radio$_r.device=radio$_r
    uci set wireless.default_radio$_r.mode=ap
    uci set wireless.default_radio$_r.network=lan
    uci set wireless.default_radio$_r.ssid=Home-Guest
    uci set wireless.default_radio$_r.encryption=psk2
    uci set wireless.default_radio$_r.key=blue-lamp-4521
done
uci commit wireless

# devices: three on Wi-Fi (5 GHz), two gone; two have no DHCP name
GB=1000000000
wifi_client hostapd.phy1-ap0 5180 aa:bb:cc:00:3c:5d aa:bb:cc:00:00:02 aa:bb:cc:00:00:03
arp_set aa:bb:cc:00:3c:5d aa:bb:cc:00:00:02 aa:bb:cc:00:00:03
lease_set "aa:bb:cc:00:3c:5d 192.168.1.20 *" "aa:bb:cc:00:00:02 192.168.1.21 Pixel-8" \
    "aa:bb:cc:00:00:03 192.168.1.22 Tablet-Lena" "aa:bb:cc:00:00:04 192.168.1.23 work-laptop"
nlbw_set "aa:bb:cc:00:3c:5d $((10 * GB + 200000000)) $((800 * 1000000))" \
    "aa:bb:cc:00:00:02 $((4 * GB)) 800000000" \
    "aa:bb:cc:00:00:03 15000000 5000000" \
    "aa:bb:cc:00:00:04 $((33 * GB)) $((3 * GB))" \
    "aa:bb:cc:00:b1:0f 3000000 2000000" \
    "00:00:00:00:00:00 300000000 200000000"

# the modem's store: 24 old SMS; the newest balance reply (9 Nov, 0.31 EUR) seeds /status
sms_n=0
old_sms() {
    sms_in "$sms_n" "$1" "$2" "$3"
    sms_n=$((sms_n + 1))
}
old_sms 38267000111 '10/21/26 18:12:00' 'Dinner at 8 on Friday? Table for four is booked.'
old_sms 38267000222 '10/22/26 09:40:00' 'Your delivery is on the way. Track it at example.org/t/55120.'
old_sms 1477 '10/23/26 07:00:00' 'Internet 500MB: 310.20MB, vazi do 01.01.2222'
old_sms 38269000333 '10/24/26 20:31:00' 'Missed call from Marko. Please call back.'
old_sms 38267000111 '10/26/26 12:05:00' 'Running ten minutes late.'
old_sms 38268000444 '10/27/26 08:15:00' 'Reminder: dentist appointment tomorrow at 14:30.'
old_sms 1466 '10/28/26 10:00:00' 'Imate: 9.40 do 05.01.; '
old_sms 38267000222 '10/29/26 16:48:00' 'Parcel left with the neighbour at number 12.'
old_sms 38269000333 '10/30/26 11:22:00' 'Thanks, got it.'
old_sms 1477 '10/31/26 07:00:00' 'Internet 500MB: 402.80MB, vazi do 01.01.2222'
old_sms 38267000111 '11/01/26 09:03:00' 'Happy November! Coffee on Sunday?'
old_sms 38268000444 '11/01/26 17:45:00' 'Your invoice 2026-114 is ready. Total 48.00 EUR.'
old_sms 1466 '11/02/26 10:00:00' 'Imate: 5.15 do 05.01.; '
old_sms 38269000333 '11/03/26 13:10:00' 'Can you send the photos from the weekend?'
old_sms 38267000222 '11/04/26 08:20:00' 'The plumber comes on Thursday between 9 and 11.'
old_sms 1477 '11/05/26 07:00:00' 'Internet 500MB: 455.10MB, vazi do 01.01.2222'
old_sms 38267000111 '11/05/26 19:30:00' 'See you at 7.'
old_sms 38268000444 '11/06/26 09:05:00' 'Your package is ready for pickup at point 14. Code: 4821.'
old_sms 38267000222 '11/07/26 12:30:00' 'Water will be off tomorrow from 9 to 13.'
old_sms 1466 '11/09/26 10:00:00' 'Imate: 0.31 do 05.01.; '
old_sms 38269000333 '11/08/26 08:41:00' 'Did the heating work this morning?'
old_sms 38267000111 '11/08/26 15:59:00' 'Are you home on Saturday? Call me on +38267000123 when you can.'
old_sms 38268000444 '11/07/26 18:02:00' 'Bus 22 is delayed by ten minutes.'
old_sms 38267000222 '11/06/26 21:14:00' 'Good night!'
[ "$sms_n" = 24 ] || lw_fail "scenario: $sms_n old SMS instead of 24"

# ---- the chat
# first start after a reset: the greeting with the reset note and the reply keyboard
kb_first_start
pass
new_bot 0
passes 3
lw_expect_eq "$(sent)" 1 "messages before the first tap"
tick 58

press 0 0 # Status
screen status
press 0 1 # Wi-Fi
screen wifi
press 0 2 # Devices
screen devices

tick 45
press 1 1 # Balance
tick 15
sms_in 24 1466 "$(smsc_ts)" 'Imate: 0.31 do 05.01.; '
n=$(sent)
passes 2
new_bot "$n"
screen balance

tick 5
press 1 2 # SMS
screen sms

press 2 0 # Alerts
tick 50
press 2 1 # Reboot
# the Cancel button of the question
Q=$(sent)
NO=$(button_data "$Q" 2)
tg_tap "$TG_CHAT" "$Q" "$NO" Alice
pass
# the transcript logs only messages that follow a tap; the cancel must edit the question
lw_expect_eq "$(sent)" "$Q" "messages after the Cancel tap"
screen alerts-reboot

press 2 2 # Help
screen help

# ---- the transcript
# jstr: stdin as a JSON string
jstr() {
    printf '"%s"' "$(sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | sed ':a;N;$!ba;s/\n/\\n/g')"
}
# jrows MARKUP KEY: the labels of an inline or reply keyboard as JSON rows
jrows() {
    _jr=0
    _jo='['
    while :; do
        _jl=$(printf '%s\n' "$1" | jsonfilter -e "@.$2[$_jr][*].text" 2>/dev/null) || _jl=
        [ -n "$_jl" ] || break
        [ "$_jr" = 0 ] || _jo="$_jo,"
        _jo="${_jo}["
        _jc=0
        while IFS= read -r _jt; do
            [ "$_jc" = 0 ] || _jo="$_jo,"
            _jo="$_jo$(printf '%s' "$_jt" | jstr)"
            _jc=$((_jc + 1))
        done <<EOF
$_jl
EOF
        _jo="$_jo]"
        _jr=$((_jr + 1))
    done
    printf '%s]' "$_jo"
}

{
    printf '{\n"title":"Home Router","members":2,\n'
    printf '"keyboard":%s,\n' "$(jrows "$(markup_of 1)" keyboard)"
    printf '"messages":[\n'
    id=0
    sep=
    : >"$T/tgp-screens"
    while IFS='|' read -r kind a b; do
        case $kind in
            s) printf '%s %s\n' "$id" "$a" >>"$T/tgp-screens" ;;
            u)
                id=$((id + 1))
                printf '%s{"id":%s,"from":"user","time":"%s","reply_to":1,"text":%s}' "$sep" "$id" "$a" \
                    "$(printf '%s' "$b" | jstr)"
                sep=',
'
                ;;
            b)
                id=$((id + 1))
                printf '%s{"id":%s,"from":"bot","time":"%s","text":%s' "$sep" "$id" "$a" \
                    "$(shown "$b" | jstr)"
                _ik=$(jrows "$(markup_of "$b")" inline_keyboard)
                [ "$_ik" = '[]' ] || printf ',"inline_keyboard":%s' "$_ik"
                printf '}'
                sep=',
'
                ;;
        esac
    done <"$EV"
    printf '\n],\n"screens":['
    sep=
    while read -r last name; do
        printf '%s{"name":"%s","last":%s}' "$sep" "$name" "$last"
        sep=','
    done <"$T/tgp-screens"
    printf ']\n}\n'
} >&3
