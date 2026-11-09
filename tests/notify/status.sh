# R39, R39c, R39d, R39e: the /status layout. The R39c scenario word for word; no signal reading,
# unreadable fields, the repair limit (R19), EDGE, offline, the signal thresholds, the Wi-Fi count,
# the restart reason, the router's time zone, and a clock that ntpd has not synced.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup 7.50
lw_uptime_set 1140
lw_net up down
sig_line -86dBm 4.6dB
wifi_set 2 1
passes 2

# status: ask /status, return the answer
status() {
    tg_push "$TG_CHAT" /status
    pass
    last_text
}
# line_of TEXT PREFIX: the first line of TEXT that starts with PREFIX
line_of() { printf '%s\n' "$1" | grep -m 1 -- "^$2" || :; }
# rating RSRP SINR: the word after "Signal: "
rating() {
    sig_line "$1" "$2"
    line_of "$(status)" '📶' | sed 's/^📶 Signal: \([a-z]*\).*/\1/'
}

# the balance reply of today 11:05 (the router reads it like any 1466 SMS)
balance_asked
sms_in 0 1466 '11/07/26 11:05:00' 'Imate: 0.31 do 05.01.; '
passes 2
expect_sent 1

# R39c scenario: -86 dBm, 4.6 dB, 0.31 EUR from today 11:05, threshold 7.50, no outage
lw_expect_eq "$(status)" "🟢 Internet works

📶 Signal: fair (4G+)
📱 Wi-Fi: 3 devices connected
💶 Balance: 0.31 EUR (today 11:05)
   ⚠️ below 7.50 EUR needed for the next data month
📊 Data this month: unknown
⏱ On since today 11:01 (power cut or manual restart)
🔧 Last outage: none recorded
⚠️ Top up at least 7.50 EUR

Tech: B3+B1 · RSRP -86 · SINR 4.6 · ping 50 ms · VPN 2 min" "the R39c scenario"
case $(last_text) in
    '🟢 Internet works'*'Tech: '*) ;;
    *) lw_fail "scenario: starts and ends wrong" ;;
esac
lw_expect_eq "$(last_text | tail -n 1 | cut -c1-5)" "Tech:" "last line"
# no technical key=value pairs outside the Tech line (R39)
if last_text | grep -v '^Tech:' | grep -q '[a-z_]=[^ ]'; then lw_fail "key=value in the answer"; fi

# the balance is above the threshold: no warning, nothing to do
balance_asked
sms_in 1 1466 '11/07/26 11:30:00' 'Imate: 12.40 do 05.01.; '
passes 2
s=$(status)
lw_expect_eq "$(line_of "$s" '💶')" "💶 Balance: 12.40 EUR (today 11:30)" "balance line"
case $s in *'below 7.50'*) lw_fail "warning above the threshold" ;; esac
lw_expect_eq "$(line_of "$s" '✅')" "✅ Nothing to do" "action line"
# an older reading that arrives later does not replace the newest
balance_asked
sms_in 2 1466 '11/06/26 18:40:00' 'Imate: 12.40 do 05.01.; '
passes 2
balance_asked
sms_in 3 1466 '11/05/26 09:12:00' 'Imate: 12.40 do 05.01.; '
passes 2
lw_expect_eq "$(cat /etc/lw-notify/lastbal)" "12.40|2026-11-07 11:30" "newest reading kept"

# no signal reading: the lines stay and say unknown (R39c); no Wi-Fi answer either
rm -f /tmp/lw-signal.log
wifi_set
s=$(status)
lw_expect_eq "$(line_of "$s" '📶')" "📶 Signal: unknown" "signal without a reading"
lw_expect_eq "$(line_of "$s" '📱')" "📱 Wi-Fi: unknown" "Wi-Fi without networks"
lw_expect_eq "$(line_of "$s" 'Tech:')" \
    "Tech: unknown · RSRP unknown · SINR unknown · ping unknown · VPN unknown" "Tech without reading"
sig_line '?' '?' '?' '?' '?'
lw_expect_eq "$(line_of "$(status)" 'Tech:')" \
    "Tech: unknown · RSRP unknown · SINR unknown · ping 50 ms · VPN 2 min" "Tech with ? fields"

# R39e thresholds, exactly: good at >= -95 and >= 10; poor below -105 or below 0; else fair
lw_expect_eq "$(rating -95dBm 10dB)" good "-95 / 10"
lw_expect_eq "$(rating -95.1dBm 10dB)" fair "-95.1 / 10"
lw_expect_eq "$(rating -95dBm 9.9dB)" fair "-95 / 9.9"
lw_expect_eq "$(rating -105dBm 0dB)" fair "-105 / 0"
lw_expect_eq "$(rating -105.1dBm 5dB)" poor "-105.1 / 5"
lw_expect_eq "$(rating -90dBm -0.1dB)" poor "-90 / -0.1"
lw_expect_eq "$(rating -100dBm 12dB)" fair "-100 / 12"
lw_expect_eq "$(rating '?' 15dB)" unknown "no RSRP, good SINR"
lw_expect_eq "$(rating -80dBm '?')" unknown "good RSRP, no SINR"
lw_expect_eq "$(rating -110dBm '?')" poor "poor RSRP, no SINR"
lw_expect_eq "$(rating '?' -3dB)" poor "no RSRP, poor SINR"
# the network name: 4G+ for LTE-A, 4G for LTE, none for an unreadable one
sig_line -86dBm 4.6dB 'LTE_B3_(1800_MHz)'
lw_expect_eq "$(line_of "$(status)" '📶')" "📶 Signal: fair (4G)" "LTE"
sig_line -86dBm 4.6dB '?'
lw_expect_eq "$(line_of "$(status)" '📶')" "📶 Signal: fair" "network unknown"
# one band only
sig_line -86dBm 4.6dB LTE-A_B3 'B3(1800MHz)' '?'
lw_expect_eq "$(line_of "$(status)" 'Tech:')" \
    "Tech: B3 · RSRP -86 · SINR 4.6 · ping 50 ms · VPN 2 min" "one band"

# the Wi-Fi count: 1 device, none, and a ubus that does not answer
sig_line -86dBm 4.6dB
wifi_set 1
lw_expect_eq "$(line_of "$(status)" '📱')" "📱 Wi-Fi: 1 device connected" "one device"
wifi_set 0 0
lw_expect_eq "$(line_of "$(status)" '📱')" "📱 Wi-Fi: 0 devices connected" "no device"
wifi_set 2
: >"$T/wifi/FAIL"
lw_expect_eq "$(line_of "$(status)" '📱')" "📱 Wi-Fi: unknown" "ubus failing"
rm -f "$T/wifi/FAIL"

# the repair limit (R19): the person line wins over the top-up line, also with a low balance
balance_asked
sms_in 4 1466 '11/07/26 11:40:00' 'Imate: 0.31 do 05.01.; '
passes 2
printf 'cycles=40\nreboots=6\nclass=hang\npassive=1\nuptime=900\n' >/etc/wwan-recover.state
s=$(status)
lw_expect_eq "$(line_of "$s" '❗')" "❗ Needs a person: unplug the router for 10 s" "limit line"
case $s in *'Top up at least'*) lw_fail "top-up line at the limit" ;; esac
# the limit and no internet: red, and the answer says why
lw_net down down
s=$(status)
lw_expect_eq "$(line_of "$s" '🔴')" "🔴 Internet does not work" "offline verdict"
lw_expect_eq "$(printf '%s\n' "$s" | sed -n 2p)" \
    "The router has used up its self-repair restarts." "offline at the limit"
# offline while repairing, and offline with no state yet
printf 'cycles=3\nreboots=0\nclass=hang\npassive=0\nuptime=900\n' >/etc/wwan-recover.state
lw_expect_eq "$(status | sed -n 2p)" "The router is trying to repair it by itself." "repairing"
rm -f /etc/wwan-recover.state
lw_expect_eq "$(status | sed -n 2p)" "The router checks the connection every 5 minutes." "no state"
lw_expect_eq "$(line_of "$(status)" '⚠️ Top')" "⚠️ Top up at least 7.50 EUR" "top-up line"

# EDGE (R22): online on 2G is orange, with what works; the signal has no rating there
: >/tmp/lw-edge
echo 0,0,0 >"$T/modem/zsnt"
lw_net down up
sig_line '?' '?' EDGE '?' '?'
s=$(status)
lw_expect_eq "$(printf '%s\n' "$s" | sed -n 1,2p)" "🟠 Internet works, but slow (2G backup)
Messages and email OK, video and calls no." "EDGE verdict"
lw_expect_eq "$(line_of "$s" '📶')" "📶 Signal: unknown (2G)" "EDGE signal"
# EDGE and no internet is red
lw_net down down
lw_expect_eq "$(status | sed -n 1p)" "🔴 Internet does not work" "EDGE offline"
rm -f /tmp/lw-edge
echo 6,0,0 >"$T/modem/zsnt"
lw_net up down

# the restart reason (R39c): decided at the first pass after the boot and kept; a failure that
# already used a self-repair reboot means the self-repair did it, passive mode means a person
lw_reboot_sim 120
wall_set '2026-11-07 11:22'
printf 'cycles=8\nreboots=1\nclass=hang\npassive=0\nuptime=900\n' >/etc/wwan-recover.state
sig_line -86dBm 4.6dB
ntp_on
# the first pass after a start only confirms what waits on the bot (R37)
pass
s=$(status)
lw_expect_eq "$(line_of "$s" '⏱')" "⏱ On since today 11:20 (restarted by self-repair)" "self-repair"
rm -f /etc/wwan-recover.state
lw_expect_grep /tmp/lw-notify/boot_reason "restarted by self-repair"
lw_expect_eq "$(line_of "$(status)" '⏱')" "⏱ On since today 11:20 (restarted by self-repair)" "kept"
lw_reboot_sim 120
wall_set '2026-11-07 11:22'
printf 'cycles=50\nreboots=6\nclass=hang\npassive=1\nuptime=900\n' >/etc/wwan-recover.state
ntp_on
pass
lw_expect_eq "$(line_of "$(status)" '⏱')" "⏱ On since today 11:20 (power cut or manual restart)" "passive"
rm -f /etc/wwan-recover.state

# a clock that ntpd has not synced: no today or yesterday, the uptime instead of a start time, and
# the plain date of the balance reading
ntp_off
s=$(status)
case $(line_of "$s" '⏱') in
    '⏱ On for 2 min (power cut or manual restart)') ;;
    *) lw_fail "unsynced clock: $(line_of "$s" '⏱')" ;;
esac
lw_expect_eq "$(line_of "$s" '💶')" "💶 Balance: 0.31 EUR (7 Nov 11:40)" "balance with an unsynced clock"
ntp_on

# the router's zone (uci system zone, /tmp/TZ): 11:20 UTC is 12:20 in a CET zone in November
echo 'CET-1CEST,M3.5.0,M10.5.0/3' >/tmp/TZ
s=$(status)
lw_expect_eq "$(line_of "$s" '⏱')" "⏱ On since today 12:20 (power cut or manual restart)" "zone"
# after midnight local time the 11:40 UTC reading is yesterday's
wall_set '2026-11-07 23:30'
lw_expect_eq "$(line_of "$(status)" '💶')" "💶 Balance: 0.31 EUR (yesterday 11:40)" "yesterday"
echo ok
