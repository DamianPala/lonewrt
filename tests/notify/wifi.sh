# R43, D58, D83: /wifi gives the names and passwords of the networks that are switched on, read from
# the current uci wireless config, each in a <code> tag a tap copies. One entry when both bands share
# name and password (no band is named); "Password: same password" for a further network that has
# it; "No password" for an open one; disabled networks, disabled radios and non-access-point
# interfaces are left out; any character in a name or password is escaped for HTML (R37g) and
# arrives as it is. Other chats get nothing, and nothing is written (R34c). The router of this test
# has no qrencode (the stand-in is off), so every answer is the text of R51's fallback, and the log
# says so once; the photo is tested in wifi-photo.sh.
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

# the same name and key on both bands: one entry, no band named
wireless HomeWifi secret-pass-1 HomeWifi secret-pass-1
lw_expect_eq "$(ask)" "📶 <b>Wi-Fi</b>
Name: <code>HomeWifi</code>
Password: <code>secret-pass-1</code>" "same name, same password"
lw_expect_eq "$(mode_of "$(sent)")" HTML "Wi-Fi reply is HTML"

# another name, the same password
wireless HomeWifi secret-pass-1 HomeWifi-5G secret-pass-1
lw_expect_eq "$(ask)" "📶 <b>Wi-Fi</b>
Name: <code>HomeWifi</code>
Password: <code>secret-pass-1</code>

Name: <code>HomeWifi-5G</code>
Password: same password" "two names, same password"

# the same name but another password: two entries, each gives its password
wireless HomeWifi secret-pass-1 HomeWifi other-pass-22
lw_expect_eq "$(ask)" "📶 <b>Wi-Fi</b>
Name: <code>HomeWifi</code>
Password: <code>secret-pass-1</code>

Name: <code>HomeWifi</code>
Password: <code>other-pass-22</code>" "same name, two passwords"

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
lw_expect_eq "$(ask)" "📶 <b>Wi-Fi</b>
Name: <code>Guest</code>
No password" "open network on both bands"
uci set wireless.default_radio1.ssid=Guest-5G
uci commit wireless
lw_expect_eq "$(ask)" "📶 <b>Wi-Fi</b>
Name: <code>Guest</code>
No password

Name: <code>Guest-5G</code>
No password" "two open networks"
# a protected first network and an open second
wireless HomeWifi secret-pass-1 HomeWifi-open x
uci set wireless.default_radio1.encryption=none
uci delete wireless.default_radio1.key
uci commit wireless
lw_expect_eq "$(ask)" "📶 <b>Wi-Fi</b>
Name: <code>HomeWifi</code>
Password: <code>secret-pass-1</code>

Name: <code>HomeWifi-open</code>
No password" "protected and open"
# switched to open in LuCI, the old key option left behind: still no password
uci set wireless.default_radio1.key=left-behind-key
uci commit wireless
lw_expect_eq "$(ask)" "📶 <b>Wi-Fi</b>
Name: <code>HomeWifi</code>
Password: <code>secret-pass-1</code>

Name: <code>HomeWifi-open</code>
No password" "open network with a key left behind"

# switched off: the network (disabled=1), the whole radio, and an interface that is not an AP
wireless HomeWifi secret-pass-1 HomeWifi-5G secret-pass-1
uci set wireless.default_radio1.disabled=1
uci commit wireless
lw_expect_eq "$(ask)" "📶 <b>Wi-Fi</b>
Name: <code>HomeWifi</code>
Password: <code>secret-pass-1</code>" "network 5 GHz disabled"
uci delete wireless.default_radio1.disabled
uci set wireless.radio0.disabled=1
uci commit wireless
lw_expect_eq "$(ask)" "📶 <b>Wi-Fi</b>
Name: <code>HomeWifi-5G</code>
Password: <code>secret-pass-1</code>" "radio 2.4 disabled"
uci delete wireless.radio0.disabled
uci set wireless.default_radio1.mode=sta
uci commit wireless
lw_expect_eq "$(ask)" "📶 <b>Wi-Fi</b>
Name: <code>HomeWifi</code>
Password: <code>secret-pass-1</code>" "a client interface is not shown"
uci set wireless.default_radio0.disabled=1
uci set wireless.default_radio1.disabled=1
uci commit wireless
lw_expect_eq "$(ask)" "📶 No Wi-Fi network is switched on." "everything off"

# no band is named, so radios without a band option or a channel change nothing
wireless HomeWifi secret-pass-1 HomeWifi-5G secret-pass-1
uci delete wireless.radio0.band
uci delete wireless.radio1.band
uci delete wireless.radio0.channel
uci delete wireless.radio1.channel
uci commit wireless
lw_expect_eq "$(ask)" "📶 <b>Wi-Fi</b>
Name: <code>HomeWifi</code>
Password: <code>secret-pass-1</code>

Name: <code>HomeWifi-5G</code>
Password: same password" "radios without band or channel"

# the config as it is now, not as it was built: a new password shows at once
wireless HomeWifi secret-pass-1 HomeWifi secret-pass-1
uci set wireless.default_radio0.key=changed-in-luci-9
uci set wireless.default_radio1.key=changed-in-luci-9
uci commit wireless
lw_expect_eq "$(ask)" "📶 <b>Wi-Fi</b>
Name: <code>HomeWifi</code>
Password: <code>changed-in-luci-9</code>" "password changed after the build"

# any character: & < > are escaped for HTML (R37g), so the chat shows the name and the password as
# they are; nothing is read as markup or as a form field
wireless "Karo's WiFi <b>&amp;" 'p&ss=w0rd%41 +x"y\n<i>' "Karo's WiFi <b>&amp;" 'p&ss=w0rd%41 +x"y\n<i>'
lw_expect_eq "$(ask)" "📶 <b>Wi-Fi</b>
Name: <code>Karo's WiFi &lt;b&gt;&amp;amp;</code>
Password: <code>p&amp;ss=w0rd%41 +x\"y\\n&lt;i&gt;</code>" "special characters"
lw_expect_eq "$(plain_of "$(last_text)")" "📶 Wi-Fi
Name: Karo's WiFi <b>&amp;
Password: p&ss=w0rd%41 +x\"y\\n<i>" "the plain-text copy shows them as they are"
wireless 'Zażółć' 'hasło-żółw-77' 'Zażółć' 'hasło-żółw-77'
lw_expect_eq "$(ask)" "📶 <b>Wi-Fi</b>
Name: <code>Zażółć</code>
Password: <code>hasło-żółw-77</code>" "UTF-8"

# the bot-name suffix, other chats, and a command from before: no answer to a foreign chat
n=$(sent)
tg_push "$TG_OTHER" /wifi
pass
lw_expect_eq "$(sent)" "$n" "answer to a foreign chat"
lw_expect_eq "$(ask '/WIFI@TestBot' | head -n 1)" "📶 <b>Wi-Fi</b>" "with the bot name"
# the token is not in the answers, and a read-only command writes nothing and logs nothing (R34c,
# R34d)
before=$(flash_state)
: >"$T/syslog"
ask >/dev/null
lw_expect_eq "$(flash_state)" "$before" "flash after /wifi"
lw_expect_eq "$(sed 's/^[0-9]* //' "$T/syslog")" \
    "lw-notify: Wi-Fi photo not sent: no QR image could be made, sent as text" "syslog after /wifi"
for f in "$G"/sent/*.text; do lw_expect_no_grep "$f" TESTtokq7x9; done
no_orphans
echo ok
