#!/usr/bin/env bash
# First boot after flash, generic profile: the "With `generic.conf`" column of the R7 table (R7, R7a),
# the build identity entry (R7b), LTE-only request (R10) and the persistent log settings (R29).
# WiFi is checked in uci only: QEMU has no radio (tests/vm/README.md).
# shellcheck disable=SC2016,SC2119 # guest scripts expand in the guest; helper args are optional
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

vm_init
vm_start
must "guest boots to the end of its init scripts" vm_wait_ready

check "all uci-defaults scripts applied and removed" vm_sh '[ -z "$(ls /etc/uci-defaults)" ]'

# LAN, system
gcheck "LAN br-lan is 192.168.1.1/24 (R7a)" \
    'i=0; until ip -4 addr show br-lan | grep -q "inet 192.168.1.1/24"; do
         i=$((i + 1)); [ $i -lt 30 ] || exit 1; sleep 1; done'
gcheck "hostname lte-router in uci and kernel" \
    '[ "$(uci get system.@system[0].hostname)" = lte-router ] &&
     [ "$(cat /proc/sys/kernel/hostname)" = lte-router ]'
tz=$(profile_value TIMEZONE)
zone=$(profile_value ZONENAME)
gcheck "timezone from generic.conf ('$tz', '$zone')" \
    "[ -n '$tz' ] && [ \"\$(uci get system.@system[0].timezone)\" = '$tz' ] &&
     [ \"\$(uci get system.@system[0].zonename)\" = '$zone' ]"

# LuCI: plain HTTP on port 80 only redirects to HTTPS (R30, D19)
gcheck "uhttpd redirects HTTP to HTTPS (R30, D19)" \
    '[ "$(uci get uhttpd.main.redirect_https)" = 1 ]'

# Watchcat: soft restart of wwan after LINK_RESTART_AFTER_S without a ping answer (R14a, D79)
link_after=$(profile_value LINK_RESTART_AFTER_S)
gcheck "watchcat wwan_soft restarts the interface after ${link_after}s (R14a)" \
    "[ -n '$link_after' ] &&
     [ \"\$(uci get watchcat.wwan_soft.mode)\" = restart_iface ] &&
     [ \"\$(uci get watchcat.wwan_soft.period)\" = '$link_after' ]"

# WiFi: both bands, one SSID and key, psk2, 802.11r, country and channels from the profile
card_wifi=$(card_value wifi)
card_root=$(card_value root)
# an empty password in the profile means a drawn one on the card; without it the checks below skip
[ -n "$(profile_value WIFI_KEY)" ] || check "password card has wifi= (R33)" test -n "$card_wifi"
[ -n "$(profile_value ROOT_PASSWORD_HASH)" ] ||
    check "password card has root= (R33)" test -n "$card_root"
gcheck "WiFi: every AP is OpenWrt-LTE, psk2, 802.11r, key from the password card" \
    "n=0
     for s in \$(uci show wireless | sed -n \"s/^wireless\\.\\([^.=]*\\)=wifi-iface\$/\\1/p\"); do
         n=\$((n + 1))
         [ \"\$(uci get wireless.\$s.ssid)\" = OpenWrt-LTE ] || { echo \"\$s ssid\"; exit 1; }
         [ \"\$(uci get wireless.\$s.encryption)\" = psk2 ] || { echo \"\$s enc\"; exit 1; }
         [ \"\$(uci -q get wireless.\$s.ieee80211r)\" = 1 ] || { echo \"\$s 11r\"; exit 1; }
         [ \"\$(uci -q get wireless.\$s.disabled)\" != 1 ] || { echo \"\$s disabled\"; exit 1; }
         k=\$(uci -q get wireless.\$s.key); [ -n \"\$k\" ] || { echo \"\$s no key\"; exit 1; }
         [ -z '$card_wifi' ] || [ \"\$k\" = '$card_wifi' ] || { echo \"\$s key != card\"; exit 1; }
     done
     [ \$n -ge 2 ] || { echo \"only \$n wifi-iface\"; exit 1; }"
country=$(profile_value WIFI_COUNTRY)
ch2=$(profile_value WIFI_CHANNEL_2G)
ch5=$(profile_value WIFI_CHANNEL_5G)
gcheck "WiFi radios: country '$country', channels '$ch2'/'$ch5' from generic.conf, enabled" \
    "[ \"\$(uci get wireless.radio0.country)\" = '$country' ] &&
     [ \"\$(uci get wireless.radio1.country)\" = '$country' ] &&
     [ \"\$(uci get wireless.radio0.channel)\" = '$ch2' ] &&
     [ \"\$(uci get wireless.radio1.channel)\" = '$ch5' ] &&
     [ \"\$(uci -q get wireless.radio0.disabled)\" != 1 ] &&
     [ \"\$(uci -q get wireless.radio1.disabled)\" != 1 ]"
gcheck "WiFi schedule off" '[ "$(uci -q get wifi_schedule.@global[0].enabled)" != 1 ]'

# LTE as the image's scripts left it, before the VM swaps QMI for DHCP (overlay zzzz-lw-vm-wwan)
gcheck "wwan from the image: QMI on /dev/cdc-wdm0, modes=lte, empty APN (R7a, R10, R13a)" \
    'f=/etc/lw-vm/wwan-from-image.uci; cat "$f"
     grep -qx "network.wwan.proto=.qmi." "$f" &&
     grep -qx "network.wwan.device=./dev/cdc-wdm0." "$f" &&
     grep -qx "network.wwan.modes=.lte." "$f" &&
     ! grep -q "^network.wwan.apn=.[^'"'"']" "$f"'
gcheck "network.wwan.modes=lte at runtime (R10)" '[ "$(uci get network.wwan.modes)" = lte ]'

# Firewall and tunnel
gcheck "firewall: wwan in zone wan, wg0 in zone vpn, vpn may forward to lan, lan not to vpn" \
    'z() { uci show firewall | sed -n "s/^firewall\.\([^.]*\)\.name=.$1.\$/\1/p" | head -n1; }
     wan=$(z wan); vpn=$(z vpn)
     uci get "firewall.$wan.network" | grep -qw wwan &&
     uci get "firewall.$vpn.network" | grep -qw wg0 &&
     uci show firewall | grep -q "src=.vpn." &&
     ! { uci show firewall | grep "src=.lan." | sed "s/\.src=.*//" |
         while read -r f; do uci -q get "$f.dest"; done | grep -qx vpn; }'
gcheck "wg0 present but disabled, no key, peer or endpoint (R32)" \
    '[ "$(uci get network.wg0.proto)" = wireguard ] &&
     [ "$(uci get network.wg0.disabled)" = 1 ] &&
     [ -z "$(uci -q get network.wg0.private_key)" ] &&
     ! uci show network | grep -qE "^network\.[^.]+\.(public_key|endpoint_host)="'

# Passwords and SSH
root_hash=$(vm_sh "sed -n 's/^root:\\([^:]*\\):.*/\\1/p' /etc/shadow" || true)
salt=$(printf '%s' "$root_hash" | cut -d'$' -f3)
check "root password is a \$6\$ hash" test "${root_hash#\$6\$}" != "$root_hash"
if [ -n "$card_root" ]; then
    check "root hash matches root= from the password card (R33)" \
        test "$(openssl passwd -6 -salt "$salt" "$card_root")" = "$root_hash"
fi
check "SSH answers on LAN (host port forward to $LAN_IP:22)" vm_py banner --run "$RUN"
gcheck "SSH host keys generated, no authorized_keys" \
    '[ -s /etc/dropbear/dropbear_ed25519_host_key ] && [ ! -s /etc/dropbear/authorized_keys ]'

# cron (R7 table row): wwan-recover every 5 min, lw-siglog 2 min later, lw-sms-clean at 04:10
gcheck "crontab: wwan-recover */5, lw-siglog 2-59/5, lw-sms-clean 10 4" \
    'c=/etc/crontabs/root; cat "$c"
     grep -qE "^\*/5 \* \* \* \* /usr/sbin/wwan-recover$" "$c" &&
     grep -qE "^(2-59/5|2,7,12,17,22,27,32,37,42,47,52,57) \* \* \* \* /usr/sbin/lw-siglog$" "$c" &&
     grep -qE "^10 4 \* \* \* /usr/sbin/lw-sms-clean$" "$c"'

# Persistent log (R29) and the build identity (R7b)
gcheck "syslog to /root/openwrt.log, 1 MB (R29)" \
    '[ "$(uci get system.@system[0].log_file)" = /root/openwrt.log ] &&
     [ "$(uci get system.@system[0].log_size)" = 1024 ] &&
     ps w | grep -q "[l]ogread -f -F /root/openwrt.log .*-S 1024" && [ -s /root/openwrt.log ]'
gcheck "/etc/lw-build has profile, build date and src hash (R7b)" \
    'cat /etc/lw-build; grep -q "^profile=generic$" /etc/lw-build &&
     grep -q "^built=." /etc/lw-build && grep -q "^src_sha256=." /etc/lw-build'
gnote 'cat /etc/lw-build; grep lw-firstboot /root/openwrt.log | tail -n1'
gcheck "lw-firstboot entry in /root/openwrt.log with the /etc/lw-build content (R7b)" \
    'i=0; until grep -q "lw-firstboot" /root/openwrt.log; do
         i=$((i + 1)); [ $i -lt 30 ] || { echo "no lw-firstboot entry"; exit 1; }; sleep 1; done
     line=$(grep "lw-firstboot" /root/openwrt.log | tail -n1); echo "$line"
     while IFS= read -r kv; do
         case "$line" in *"$kv"*) ;; *) echo "missing: $kv"; exit 1 ;; esac
     done </etc/lw-build'

# The bench itself: the real sms_tool talks to the modem stand-in on the AT port
gcheck "sms_tool on /dev/ttyUSB2 gets +ZSNT from the modem stand-in" \
    'flock /tmp/lw-at.lock timeout 15 sms_tool -d /dev/ttyUSB2 at "AT+ZSNT?" | grep -q "^+ZSNT: "'

finish
