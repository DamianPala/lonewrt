# R43, D58: /wifi gives the names and passwords of the networks that are switched on, read from the
# current uci wireless config. One entry when both bands share name and password; "same password"
# for a further network that has it; "no password" for an open one; disabled networks, disabled
# radios and non-access-point interfaces are left out; plain text, so any character in a name or
# password arrives as it is. Other chats get nothing, and nothing is written (R34c).
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup 7.50
passes 2

# radios 2.4 and 5 GHz with one network each, as the image's first boot leaves them
# ap N SSID KEY: network N (0 = 2.4 GHz, 1 = 5 GHz) as an access point on its radio
ap() {
    uci set wireless.default_radio"$1"=wifi-iface
    uci set wireless.default_radio"$1".device=radio"$1"
    uci set wireless.default_radio"$1".mode=ap
    uci set wireless.default_radio"$1".network=lan
    uci set wireless.default_radio"$1".ssid="$2"
    uci set wireless.default_radio"$1".encryption=psk2
    uci set wireless.default_radio"$1".key="$3"
}
# wireless SSID0 KEY0 SSID1 KEY1: both radios and both networks
wireless() {
    : >/etc/config/wireless
    uci set wireless.radio0=wifi-device
    uci set wireless.radio0.band=2g
    uci set wireless.radio0.channel=auto
    uci set wireless.radio1=wifi-device
    uci set wireless.radio1.band=5g
    uci set wireless.radio1.channel=auto
    ap 0 "$1" "$2"
    ap 1 "$3" "$4"
    uci commit wireless
}
ask() {
    tg_push "$TG_CHAT" "${1:-/wifi}"
    pass
    last_text
}
flash_state() {
    find /etc /root -type f -exec ls -li {} + | sort
    find /etc /root -type f -exec md5sum {} + | sort
}

# the same name and key on both bands: one entry
wireless HomeWifi secret-pass-1 HomeWifi secret-pass-1
lw_expect_eq "$(ask)" "📶 Wi-Fi for guests

Name: HomeWifi (2.4 + 5 GHz)
Password: secret-pass-1" "same name, same password"

# another name, the same password
wireless HomeWifi secret-pass-1 HomeWifi-5G secret-pass-1
lw_expect_eq "$(ask)" "📶 Wi-Fi for guests

Name: HomeWifi (2.4 GHz)
Password: secret-pass-1
5 GHz: HomeWifi-5G (same password)" "two names, same password"

# the same name but another password: two entries, the second gives its password
wireless HomeWifi secret-pass-1 HomeWifi other-pass-22
lw_expect_eq "$(ask)" "📶 Wi-Fi for guests

Name: HomeWifi (2.4 GHz)
Password: secret-pass-1
5 GHz: HomeWifi (password: other-pass-22)" "same name, two passwords"

# open networks
uci -q batch <<'UCI'
set wireless.default_radio0.ssid=Guest
set wireless.default_radio0.encryption=none
delete wireless.default_radio0.key
set wireless.default_radio1.ssid=Guest
set wireless.default_radio1.encryption=none
delete wireless.default_radio1.key
commit wireless
UCI
lw_expect_eq "$(ask)" "📶 Wi-Fi for guests

Name: Guest (2.4 + 5 GHz)
Password: no password" "open network on both bands"
uci set wireless.default_radio1.ssid=Guest-5G
uci commit wireless
lw_expect_eq "$(ask)" "📶 Wi-Fi for guests

Name: Guest (2.4 GHz)
Password: no password
5 GHz: Guest-5G (no password)" "two open networks"
# a protected first network and an open second
wireless HomeWifi secret-pass-1 HomeWifi-open x
uci set wireless.default_radio1.encryption=none
uci delete wireless.default_radio1.key
uci commit wireless
lw_expect_eq "$(ask)" "📶 Wi-Fi for guests

Name: HomeWifi (2.4 GHz)
Password: secret-pass-1
5 GHz: HomeWifi-open (no password)" "protected and open"
# switched to open in LuCI, the old key option left behind: still no password
uci set wireless.default_radio1.key=left-behind-key
uci commit wireless
lw_expect_eq "$(ask)" "📶 Wi-Fi for guests

Name: HomeWifi (2.4 GHz)
Password: secret-pass-1
5 GHz: HomeWifi-open (no password)" "open network with a key left behind"

# switched off: the network (disabled=1), the whole radio, and an interface that is not an AP
wireless HomeWifi secret-pass-1 HomeWifi-5G secret-pass-1
uci set wireless.default_radio1.disabled=1
uci commit wireless
lw_expect_eq "$(ask)" "📶 Wi-Fi for guests

Name: HomeWifi (2.4 GHz)
Password: secret-pass-1" "network 5 GHz disabled"
uci delete wireless.default_radio1.disabled
uci set wireless.radio0.disabled=1
uci commit wireless
lw_expect_eq "$(ask)" "📶 Wi-Fi for guests

Name: HomeWifi-5G (5 GHz)
Password: secret-pass-1" "radio 2.4 disabled"
uci delete wireless.radio0.disabled
uci set wireless.default_radio1.mode=sta
uci commit wireless
lw_expect_eq "$(ask)" "📶 Wi-Fi for guests

Name: HomeWifi (2.4 GHz)
Password: secret-pass-1" "a client interface is not shown"
uci set wireless.default_radio0.disabled=1
uci set wireless.default_radio1.disabled=1
uci commit wireless
lw_expect_eq "$(ask)" "📶 No Wi-Fi network is switched on." "everything off"

# the band from the channel when the radio has no band option; unknown band: no brackets
wireless HomeWifi secret-pass-1 HomeWifi-5G secret-pass-1
uci delete wireless.radio0.band
uci delete wireless.radio1.band
uci set wireless.radio0.channel=6
uci set wireless.radio1.channel=100
uci commit wireless
lw_expect_eq "$(ask)" "📶 Wi-Fi for guests

Name: HomeWifi (2.4 GHz)
Password: secret-pass-1
5 GHz: HomeWifi-5G (same password)" "bands from channels"
uci set wireless.radio0.channel=auto
uci set wireless.radio1.channel=auto
uci commit wireless
lw_expect_eq "$(ask)" "📶 Wi-Fi for guests

Name: HomeWifi
Password: secret-pass-1
Also: HomeWifi-5G (same password)" "bands unknown"

# the config as it is now, not as it was built: a new password shows at once
wireless HomeWifi secret-pass-1 HomeWifi secret-pass-1
uci set wireless.default_radio0.key=changed-in-luci-9
uci set wireless.default_radio1.key=changed-in-luci-9
uci commit wireless
lw_expect_eq "$(ask)" "📶 Wi-Fi for guests

Name: HomeWifi (2.4 + 5 GHz)
Password: changed-in-luci-9" "password changed after the build"

# any character: plain text, nothing is read as markup or as a form field
wireless "Karo's WiFi <b>&amp;" 'p&ss=w0rd%41 +x"y\n' "Karo's WiFi <b>&amp;" 'p&ss=w0rd%41 +x"y\n'
lw_expect_eq "$(ask)" "📶 Wi-Fi for guests

Name: Karo's WiFi <b>&amp; (2.4 + 5 GHz)
Password: p&ss=w0rd%41 +x\"y\\n" "special characters"
wireless 'Zażółć' 'hasło-żółw-77' 'Zażółć' 'hasło-żółw-77'
lw_expect_eq "$(ask)" "📶 Wi-Fi for guests

Name: Zażółć (2.4 + 5 GHz)
Password: hasło-żółw-77" "UTF-8"

# the bot-name suffix, other chats, and a command from before: no answer to a foreign chat
n=$(sent)
tg_push "$TG_OTHER" /wifi
pass
lw_expect_eq "$(sent)" "$n" "answer to a foreign chat"
lw_expect_eq "$(ask '/WIFI@TestBot' | head -n 1)" "📶 Wi-Fi for guests" "with the bot name"
# the token is not in the answers, and a read-only command writes nothing and logs nothing (R34c,
# R34d)
before=$(flash_state)
ask >/dev/null
lw_expect_eq "$(flash_state)" "$before" "flash after /wifi"
lw_expect_eq "$(cat "$T/syslog")" "" "syslog after /wifi"
for f in "$G"/sent/*.text; do lw_expect_no_grep "$f" TESTtokq7x9; done
no_orphans
echo ok
