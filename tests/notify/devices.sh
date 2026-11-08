# R44, R44b, D59, D63: /devices lists every device with traffic this calendar month in two groups,
# connected now (Wi-Fi with the band, cable) and not connected now, each biggest first, at most 20 in
# all (the smallest drop off the list but stay in the total), the router's own traffic as a line of
# its own, and the month's total with "since 1 <month>"; the same total is the data line of /status
# (R39c). A device without a DHCP name is "Unknown device (...xx:xx)"; a name stays after the lease is
# gone, also over a restart of the router, written to flash at most once a day. Without nlbwmon or
# without a clock set by ntpd the numbers are "unknown", not guesses (R44a).
# shellcheck disable=SC2119  # wifi_set without arguments clears all stations
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup 7.50
passes 2

ask() {
    tg_push "$TG_CHAT" "${1:-/devices}"
    pass
    last_text
}
flash_state() {
    find /etc /root -type f -exec ls -li {} + | sort
    find /etc /root -type f -exec md5sum {} + | sort
}
GB=1000000000

# The R44 picture: two phones and an unnamed one on Wi-Fi, a PC on the cable, a laptop that is not
# here any more but used 24.9 GB, and the router's own speed tests
wifi_client hostapd.phy0-ap0 2437 aa:bb:cc:00:00:02 66:8a:a5:ac:6e:94 aa:bb:cc:00:00:09=noassoc
wifi_client hostapd.phy1-ap0 5180 aa:bb:cc:00:00:01
arp_set aa:bb:cc:00:00:01 aa:bb:cc:00:00:02 66:8a:a5:ac:6e:94 aa:bb:cc:00:00:07
lease_set "aa:bb:cc:00:00:01 192.168.1.20 Alice-iPhone" "aa:bb:cc:00:00:02 192.168.1.21 Galaxy-S21" \
    "66:8a:a5:ac:6e:94 192.168.1.22 *" "aa:bb:cc:00:00:07 192.168.1.23 cable-pc" \
    "11:22:33:44:55:66 192.168.1.24 old-laptop"
nlbw_set "aa:bb:cc:00:00:01 $((12 * GB)) 400000000" \
    "aa:bb:cc:00:00:02 $((2 * GB)) 1100000000" \
    "66:8a:a5:ac:6e:94 130350000 50000000" \
    "aa:bb:cc:00:00:07 800000000 100000000" \
    "11:22:33:44:55:66 $((20 * GB)) $((4900000000))" \
    "00:00:00:00:00:00 300000000 200000000"
# Alice-iPhone: 12.0 + 0.4 = 12.4 GB; Galaxy-S21: 2 + 1.1 = 3.1; unnamed: 0.18 -> 0.2; PC 0.9;
# old laptop 24.9; router 0.5; total 42.0
EXPECT="📱 Devices this month: 5 (4 connected now)

Connected now:
• Alice-iPhone · 5 GHz · 12.4 GB
• Galaxy-S21 · 2.4 GHz · 3.1 GB
• cable-pc · cable · 0.9 GB
• Unknown device (…6e:94) · 2.4 GHz · 0.2 GB

Not connected now:
• old-laptop · 24.9 GB

• Router itself · 0.5 GB
Data this month: 42 GB (since 1 Nov)"
lw_expect_eq "$(ask)" "$EXPECT" "the R44 picture"
# no flash write, no log line for a read-only command (R34c)
before=$(flash_state)
ask >/dev/null
lw_expect_eq "$(flash_state)" "$before" "flash after /devices"
lw_expect_eq "$(cat "$T/syslog")" "" "syslog after /devices"

# /status: the data line sits under the speed test line (here none) and above the start time
tg_push "$TG_CHAT" /status
pass
case $(last_text) in
    *'💶 Balance: unknown
📊 Data this month: 42 GB (since 1 Nov)
⏱ On '*) ;;
    *) lw_fail "no data line in /status: $(last_text)" ;;
esac
# ... and under the speed test line when there is one (tests/notify/speedtest.sh has the test)
lw_expect_eq "$(last_text | grep -c '^📊')" 1 "data lines in /status"

# the same text through the long JSON the client may print, and the bot-name suffix
mkdir -p "$T/nlbw"
touch "$T/nlbw/pretty"
lw_expect_eq "$(ask '/DEVICES@TestBot')" "$EXPECT" "pretty JSON"
rm -f "$T/nlbw/pretty"

# the month rolls over: the label follows the clock, the totals follow nlbwmon
wall_set '2026-12-01 00:05'
nlbw_set "aa:bb:cc:00:00:01 1000000000 200000000"
case $(ask) in
    *'Data this month: 1.2 GB (since 1 Dec)') ;;
    *) lw_fail "December label: $(last_text)" ;;
esac
wall_set '2026-11-07 11:20'

# small totals: one decimal under 10 GB, "<0.1 GB" under 50 MB, whole GB from 10
nlbw_set "aa:bb:cc:00:00:01 $((4 * GB)) 200000000"
case $(ask) in *'Data this month: 4.2 GB (since 1 Nov)') ;; *) lw_fail "4.2 GB: $(last_text)" ;; esac
nlbw_set "aa:bb:cc:00:00:01 10000000 20000000"
case $(ask) in
    *'• Alice-iPhone · 5 GHz · <0.1 GB'*'Data this month: <0.1 GB (since 1 Nov)') ;;
    *) lw_fail "<0.1 GB: $(last_text)" ;;
esac
nlbw_set "aa:bb:cc:00:00:01 $((9 * GB)) 1600000000"
case $(ask) in *'Data this month: 11 GB (since 1 Nov)') ;; *) lw_fail "11 GB: $(last_text)" ;; esac
# the router itself without traffic: no line for it
nlbw_set "aa:bb:cc:00:00:01 1000000000 0" "00:00:00:00:00:00 0 0"
! ask | grep -q 'Router itself' || lw_fail "a line for the router without traffic"

# nlbwmon is not running: the devices stay, the numbers are unknown
rm -f /tmp/nlbw-mem
lw_expect_eq "$(ask)" "📱 Devices connected now: 4

• Alice-iPhone · 5 GHz
• Galaxy-S21 · 2.4 GHz
• Unknown device (…6e:94) · 2.4 GHz
• cable-pc · cable

Data this month: unknown" "without nlbwmon"
tg_push "$TG_CHAT" /status
pass
case $(last_text) in
    *'📊 Data this month: unknown
⏱ On '*) ;;
    *) lw_fail "/status without nlbwmon: $(last_text)" ;;
esac

# ntpd has not set the clock: the month is not known, so no number (R44a)
nlbw_set "aa:bb:cc:00:00:01 $((9 * GB)) 1600000000"
ntp_off
case $(ask) in
    *'• Alice-iPhone · 5 GHz
'*'Data this month: unknown (the router clock is not set yet)') ;;
    *) lw_fail "without NTP: $(last_text)" ;;
esac
tg_push "$TG_CHAT" /status
pass
case $(last_text) in *'📊 Data this month: unknown'*) ;; *) lw_fail "/status without NTP" ;; esac
ntp_on

# names: a lease that gave none keeps the name the device had (R44b), a name with control characters
# is cleaned, a MAC in capitals is the same device, a device that never had a name is unknown
lease_set "aa:bb:cc:00:00:01 192.168.1.20 *" "aa:bb:cc:00:00:03 192.168.1.25 *"
printf '1794000000 AA:BB:CC:00:00:02 192.168.1.21 Ga\001la\177xy 01:aa\n' >>"$T/leases"
wifi_client hostapd.phy1-ap0 5180 aa:bb:cc:00:00:01 aa:bb:cc:00:00:03
nlbw_set "aa:bb:cc:00:00:01 $((9 * GB)) 0" "aa:bb:cc:00:00:02 $((1 * GB)) 0" \
    "aa:bb:cc:00:00:03 500000000 0"
s=$(ask)
case $s in *'• Alice-iPhone · 5 GHz · 9.0 GB'*) ;; *) lw_fail "name lost with the lease: $s" ;; esac
case $s in *'• Unknown device (…00:03) · 5 GHz · 0.5 GB'*) ;; *) lw_fail "unnamed on 5 GHz: $s" ;; esac
case $s in *'• Galaxy · 2.4 GHz · 1.0 GB'*) ;; *) lw_fail "name with control characters: $s" ;; esac

# one device: singular count in the heading; the name outlives the lease
wifi_set
arp_set
lease_set
wifi_client hostapd.phy0-ap0 2437 aa:bb:cc:00:00:02
nlbw_set "aa:bb:cc:00:00:02 $((1 * GB)) 0"
case $(ask) in '📱 Devices this month: 1 (1 connected now)
'*) ;; *) lw_fail "one device: $(last_text)" ;; esac
wifi_set
lw_expect_eq "$(ask)" "📱 Devices this month: 1 (0 connected now)

Not connected now:
• Galaxy · 1.0 GB

Data this month: 1.0 GB (since 1 Nov)" "nobody connected"
# no traffic and nobody here: no device, and the name is forgotten (names of this month only)
nlbw_set
lw_expect_eq "$(ask)" "📱 Devices this month: 0 (0 connected now)

Data this month: <0.1 GB (since 1 Nov)" "no devices"

# ARP: incomplete entries, other interfaces and a Wi-Fi device are not cable devices
nlbw_set "aa:bb:cc:00:00:02 $((1 * GB)) 0"
wifi_client hostapd.phy0-ap0 2437 aa:bb:cc:00:00:02
printf 'IP address HW type Flags HW address Mask Device\n' >"$T/arp"
{
    echo '192.168.1.30 0x1 0x0 aa:bb:cc:00:00:30 * br-lan'
    echo '10.0.0.5 0x1 0x2 aa:bb:cc:00:00:31 * wwan0'
    echo '192.168.1.31 0x1 0x2 aa:bb:cc:00:00:02 * br-lan'
    echo '192.168.1.32 0x1 0x2 AA:BB:CC:00:00:32 * br-lan'
} >>"$T/arp"
s=$(ask)
case $s in
    *'Devices this month: 2 (2 connected now)'*'(…00:02) · 2.4 GHz · 1.0 GB'*'(…00:32) · cable · <0.1 GB'*) ;;
    *) lw_fail "ARP entries: $s" ;;
esac
case $s in *00:30* | *00:31*) lw_fail "an incomplete or foreign ARP entry is listed: $s" ;; esac
lw_expect_eq "$(printf '%s\n' "$s" | grep -c 'Unknown device (…00:02)')" 1 "a Wi-Fi device listed twice"

# 25 devices (15 connected, 10 not) and the router itself: 20 are listed, the smallest of either
# group drop off, the heading and the sum still count all 25 (R44)
wifi_set
arp_set
lease_set
i=1
macs=
: >/tmp/nlbw-mem
while [ "$i" -le 15 ]; do
    m=$(printf 'aa:bb:cc:01:00:%02x' "$i")
    macs="$macs $m"
    echo "$m $((i * 100000000)) 0" >>/tmp/nlbw-mem
    i=$((i + 1))
done
while [ "$i" -le 25 ]; do
    echo "$(printf 'bb:bb:cc:02:00:%02x' $((i + 112))) $((i * 100000000)) 0" >>/tmp/nlbw-mem
    i=$((i + 1))
done
echo "00:00:00:00:00:00 100000000 0" >>/tmp/nlbw-mem
# shellcheck disable=SC2086  # one argument per MAC
wifi_client hostapd.phy0-ap0 2437 $macs
s=$(ask)
lw_expect_eq "$(printf '%s\n' "$s" | grep -c '^• ')" 21 "listed devices and the router"
case $s in '📱 Devices this month: 25 (15 connected now)
'*) ;; *) lw_fail "heading of 25 devices: $s" ;; esac
case $s in *'…and 5 more'*'• Router itself · 0.1 GB
Data this month: 33 GB (since 1 Nov)') ;; *) lw_fail "tail of 25 devices: $s" ;; esac
# 100 MB steps: connected 6..15 (0.6 to 1.5 GB) and not connected 16..25 (1.6 to 2.5 GB) are listed
lw_expect_eq "$(printf '%s\n' "$s" | sed -n '/^Connected now:/,/^$/p' | grep -c '^•')" 10 "connected listed"
lw_expect_eq "$(printf '%s\n' "$s" | sed -n '/^Not connected now:/,/^$/p' | grep -c '^•')" 10 \
    "not connected listed"
lw_expect_eq "$(printf '%s\n' "$s" | sed -n '/^Connected now:/,/^$/p' | sed -n 2p)" \
    "• Unknown device (…00:0f) · 2.4 GHz · 1.5 GB" "biggest connected"
lw_expect_eq "$(printf '%s\n' "$s" | sed -n '/^Connected now:/,/^$/p' | grep '^•' | tail -n 1)" \
    "• Unknown device (…00:06) · 2.4 GHz · 0.6 GB" "smallest connected listed"
lw_expect_eq "$(printf '%s\n' "$s" | sed -n '/^Not connected now:/,/^$/p' | sed -n 2p)" \
    "• Unknown device (…00:89) · 2.5 GB" "biggest not connected"
lw_expect_eq "$(printf '%s\n' "$s" | sed -n '/^Not connected now:/,/^$/p' | grep '^•' | tail -n 1)" \
    "• Unknown device (…00:80) · 1.6 GB" "smallest not connected listed"
case $s in *'(…00:05)'*) lw_fail "a device under the cut is listed: $s" ;; esac

# R44b, the scenario of the SPEC: the TV used 18.2 GB in the evening, is off, and its lease has run
# out; in the morning it is listed under "Not connected now" with its name, and the sum has it. The
# poll loop saw the lease while the TV was on, and the name went to flash (once, with a stamp).
rm -rf /etc/lw-notify/names /tmp/lw-notify/names /tmp/lw-notify/names_dirty /tmp/lw-notify/leases.sum
wifi_set
wifi_client hostapd.phy0-ap0 2437 aa:bb:cc:00:00:40
lease_set "aa:bb:cc:00:00:40 192.168.1.60 Anna-iPhone" "aa:bb:cc:00:00:41 192.168.1.61 LG-TV"
nlbw_set "aa:bb:cc:00:00:40 $((3 * GB)) 0" "aa:bb:cc:00:00:41 18000000000 200000000"
pass
lw_expect_eq "$(tail -n +2 /etc/lw-notify/names)" "aa:bb:cc:00:00:40 Anna-iPhone
aa:bb:cc:00:00:41 LG-TV" "names on flash after the first pass"
lw_expect_eq "$(head -n 1 /etc/lw-notify/names)" "$(cat "$T/wall")" "stamp of the names file"
lease_set "aa:bb:cc:00:00:40 192.168.1.60 Anna-iPhone"
TV="📱 Devices this month: 2 (1 connected now)

Connected now:
• Anna-iPhone · 2.4 GHz · 3.0 GB

Not connected now:
• LG-TV · 18.2 GB

Data this month: 21 GB (since 1 Nov)"
lw_expect_eq "$(ask)" "$TV" "LG-TV after its lease ran out"
# ... and after the router restarted: /tmp is empty, the leases are those of the new boot, nlbwmon
# brings its counters back from its own database, and before ntpd has set the clock nothing is
# written to flash
ls_names() { ls -li /etc/lw-notify/names; md5sum /etc/lw-notify/names; }
before=$(ls_names)
reboot_sim
ntp_off
nlbw_set "aa:bb:cc:00:00:40 $((3 * GB)) 0" "aa:bb:cc:00:00:41 18000000000 200000000"
lease_set "aa:bb:cc:00:00:40 192.168.1.60 Anna-iPhone" "aa:bb:cc:00:00:44 192.168.1.64 New-Tablet"
wall_add 90000
passes 2
lw_expect_eq "$(ls_names)" "$before" "names file before ntpd set the clock"
ntp_on
lw_expect_eq "$(ask)" "$TV" "LG-TV after a restart of the router"
# the day is over and ntpd is up: the first look writes the new name, the old ones are still there
case $(tail -n +2 /etc/lw-notify/names) in
    *'aa:bb:cc:00:00:41 LG-TV'*'aa:bb:cc:00:00:44 New-Tablet'*) ;;
    *) lw_fail "names after the restart: $(cat /etc/lw-notify/names)" ;;
esac

# flash writes of the names: only a change, at most once a day (R44a)
before=$(ls_names)
nlbw_set "aa:bb:cc:00:00:40 $((3 * GB)) 0" "aa:bb:cc:00:00:41 18000000000 200000000" \
    "aa:bb:cc:00:00:44 100000000 0" "aa:bb:cc:00:00:47 100000000 0"
lease_set "aa:bb:cc:00:00:40 192.168.1.60 Anna-iPhone" "aa:bb:cc:00:00:44 192.168.1.64 New-Tablet" \
    "aa:bb:cc:00:00:47 192.168.1.67 Guest-Laptop"
wall_add 3600
passes 3
lw_expect_eq "$(ls_names)" "$before" "names file within a day of the last write"
case $(ask) in *'• Guest-Laptop · 0.1 GB'*) ;; *) lw_fail "new name not in RAM: $(last_text)" ;; esac
lw_expect_eq "$(ls_names)" "$before" "names file after /devices within the day"
wall_add 90000
pass
after=$(ls_names)
[ "$after" != "$before" ] || lw_fail "names file not written when due"
case $(tail -n +2 /etc/lw-notify/names) in *'aa:bb:cc:00:00:47 Guest-Laptop'*) ;; *) lw_fail "no new name" ;; esac
wall_add 90000
passes 3
lw_expect_eq "$(ls_names)" "$after" "names file rewritten without a change"

# the service stops: what is not on flash yet is written, though the day is not over (the clock
# goes back to a few hours after the last write)
wall_add -80000
lease_set "aa:bb:cc:00:00:40 192.168.1.60 Anna-iPhone" "aa:bb:cc:00:00:44 192.168.1.64 New-Tablet" \
    "aa:bb:cc:00:00:45 192.168.1.65 Late-Phone"
nlbw_set "aa:bb:cc:00:00:40 $((3 * GB)) 0" "aa:bb:cc:00:00:41 18000000000 200000000" \
    "aa:bb:cc:00:00:44 100000000 0" "aa:bb:cc:00:00:45 100000000 0"
LW_NOTIFY_CLOCK=/proc/uptime LW_NOTIFY_POLL=2 LW_NOTIFY_LONGPOLL=1 lw-notify run </dev/null \
    >/dev/null 2>&1 &
svc=$!
sleep 4
case $(tail -n +2 /etc/lw-notify/names) in *Late-Phone*) lw_fail "written within the day" ;; esac
kill -TERM "$svc"
wait "$svc" || :
case $(tail -n +2 /etc/lw-notify/names) in *'aa:bb:cc:00:00:45 Late-Phone'*) ;; *) lw_fail "not written on stop" ;; esac

# ... and before a restart asked in the chat (R45), which needs no clock check beyond ntpd
lease_set "aa:bb:cc:00:00:40 192.168.1.60 Anna-iPhone" "aa:bb:cc:00:00:45 192.168.1.65 Late-Phone" \
    "aa:bb:cc:00:00:46 192.168.1.66 Last-Laptop"
nlbw_set "aa:bb:cc:00:00:40 $((3 * GB)) 0" "aa:bb:cc:00:00:45 100000000 0" \
    "aa:bb:cc:00:00:46 100000000 0"
passes 2
tg_push "$TG_CHAT" /reboot
pass
q=$(sent)
tg_tap "$TG_CHAT" "$q" "$(button_data "$q" 1)"
pass
lw_expect_eq "$(grep -c '^reboot' "$T/events")" 1 "restart after the tap"
case $(tail -n +2 /etc/lw-notify/names) in *'aa:bb:cc:00:00:46 Last-Laptop'*) ;; *) lw_fail "not written before the restart" ;; esac
rm -f /etc/lw-notify/reboot
: >"$T/events"

# names are kept for the current month only: a MAC that has neither traffic nor a lease is dropped
# from the list, on flash too at the next write, and shows as unknown if it turns up again
lease_set
nlbw_set "aa:bb:cc:00:00:40 $((3 * GB)) 0"
wifi_set
case $(ask) in *'• Anna-iPhone · 3.0 GB'*) ;; *) lw_fail "name with traffic lost: $(last_text)" ;; esac
wall_add 90000
pass
if grep -q 'LG-TV\|Late-Phone' /etc/lw-notify/names; then lw_fail "old names kept on flash"; fi
nlbw_set "aa:bb:cc:00:00:40 $((3 * GB)) 0" "aa:bb:cc:00:00:41 18000000000 200000000"
case $(ask) in *'• Unknown device (…00:41) · 18.2 GB'*) ;; *) lw_fail "old name came back: $(last_text)" ;; esac

# other chats get nothing
n=$(sent)
tg_push "$TG_OTHER" /devices
pass
lw_expect_eq "$(sent)" "$n" "answer to a foreign chat"
no_orphans
echo ok
