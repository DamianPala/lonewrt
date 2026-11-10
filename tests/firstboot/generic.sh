# First boot of the generic image (SPEC R7a table column "With `generic.conf`", R32, R7b, R8a).
# shellcheck source=tests/firstboot/fb-lib
. /fw/tests/firstboot/fb-lib
fb_prepare generic
SYSLOG=$LW_TEST/syslog
card=$RENDER/generic-passwords.txt
wifi=$(sed -n 's/^wifi=//p' "$card")
fb_uci_defaults

# LAN, system, persistent log
fb_expect network.lan.ipaddr 192.168.1.1/24
fb_expect network.lan.netmask "<unset>"
fb_expect system.@system[0].hostname lte-router
fb_expect system.@system[0].zonename Europe/Warsaw
fb_expect system.@system[0].log_file /root/openwrt.log
fb_expect system.@system[0].log_size 1024
fb_expect system.@system[0].cronloglevel 9

# WiFi: both radios, one SSID and the card's key, psk2, 802.11r, PL, schedule off
for r in radio0 radio1; do
    fb_expect wireless.$r.country PL
    fb_expect wireless.$r.channel auto
    fb_expect wireless.$r.disabled "<unset>"
    fb_expect wireless.default_$r.ssid OpenWrt-LTE
    fb_expect wireless.default_$r.key "$wifi"
    fb_expect wireless.default_$r.encryption psk2
    fb_expect wireless.default_$r.ieee80211r 1
    fb_expect wireless.default_$r.disabled "<unset>"
done
fb_expect wireless.radio0.htmode HT20
fb_expect wireless.radio1.htmode VHT80
fb_expect wifi_schedule.@global[0].enabled 0

# LTE: QMI, LTE only, empty APN; no band target
fb_expect network.wwan.proto qmi
fb_expect network.wwan.device /dev/cdc-wdm0
fb_expect network.wwan.modes lte
fb_expect network.wwan.apn "<unset>"
fb_expect network.wwan.auth "<unset>"
fb_expect lonewrt.modem.bands "<unset>"

# WireGuard: wg0 and the vpn zone exist, wg0 disabled, no key, peer or endpoint (R32)
fb_expect network.wg0.proto wireguard
fb_expect network.wg0.disabled 1
fb_expect network.wg0.private_key "<unset>"
fb_expect network.wg0.addresses "<unset>"
uci -q get network.wg_server >/dev/null && lw_fail "generic image has a WireGuard peer"
uci show network | grep -q "=wireguard_wg0$" && lw_fail "generic image has a WireGuard peer"

# Firewall: wwan in wan, wg0 in vpn, vpn may reach lan, lan has no way into vpn (R31a)
uci show firewall | grep -q "\.network=.*'wwan'" || lw_fail "wwan is not in a firewall zone"
fb_expect firewall.vpn.network wg0
fb_expect firewall.vpn.forward REJECT
fb_expect firewall.vpn_lan.src vpn
fb_expect firewall.vpn_lan.dest lan
uci show firewall | grep -q "dest='vpn'" && lw_fail "a forwarding leads into the vpn zone"

# LuCI answers on port 80 only with a redirect to HTTPS, so the root password never crosses the Wi-Fi
# in clear text (R30, D19); the rest of the uhttpd section stays as the package has it
fb_expect uhttpd.main.redirect_https 1
fb_expect uhttpd.main.home /www
fb_expect uhttpd.main.listen_https "0.0.0.0:443 [::]:443"

# LuCI modem tools on ttyUSB1 (R12, R30a)
fb_expect sms_tool_js.@sms_tool_js[0].atport /dev/ttyUSB1
fb_expect sms_tool_js.@sms_tool_js[0].storage ME
fb_expect modemband.@modemband[0].set_port /dev/ttyUSB1
fb_expect modemband.@modemband[0].iface wwan
fb_expect defmodems.mf289f.comm_port /dev/ttyUSB1
fb_expect defmodems.@general[0].main_modem mf289f

# Root password from the card (hash checked against the card on the host), SSH without profile keys
grep -q "^root:\\\$6\\\$" /etc/shadow || lw_fail "root has no \$6\$ hash"
grep -qF "root:$(sed -n "s/^P_ROOT_PASSWORD_HASH='\(.*\)'$/\1/p" "$RENDER/generic/etc/uci-defaults/zz-lw-config"):" \
    /etc/shadow || lw_fail "root hash is not the rendered one"
[ ! -e /etc/dropbear/authorized_keys ] || lw_fail "generic image has authorized_keys"

# Watchcat: the soft restart of wwan after 120 s without a ping answer (R14a, D79), pings as before
fb_expect watchcat.wwan_soft.mode restart_iface
fb_expect watchcat.wwan_soft.period 120
fb_expect watchcat.wwan_soft.pingperiod 60

# Cron table and services
printf '%s\n' '*/5 * * * * /usr/sbin/wwan-recover' '2-59/5 * * * * /usr/sbin/lw-siglog' \
    '10 4 * * * /usr/sbin/lw-sms-clean' | cmp -s - /etc/crontabs/root || lw_fail "crontab differs"
# R42, R4: no heartbeat address in the generic image, so no cron line and no option
fb_expect lonewrt.heartbeat.url "<unset>"
# R46: no SMS admins in the generic image
fb_expect lonewrt.notify.sms_admins "<unset>"
lw_expect_eq "$(find /etc/config/lonewrt -perm 600)" /etc/config/lonewrt "mode of /etc/config/lonewrt"
! grep -q heartbeat /etc/crontabs/root || lw_fail "generic image has a heartbeat cron line"
for s in lw-modem-mode lw-firstboot cron; do
    ls /etc/rc.d/S*"$s" >/dev/null 2>&1 || lw_fail "$s is not enabled"
done

# R8a: a second run (power lost before boot removed the script) changes nothing
first=$(fb_state)
fb_uci_defaults
lw_expect_eq "$(fb_state)" "$first" "state after a second uci-defaults run"

# R7b: once syslog runs, lw-firstboot logs /etc/lw-build and clears its marker
[ -f /etc/lw-firstboot.pending ] || lw_fail "no first-boot marker"
/etc/init.d/lw-firstboot start
i=0
while [ -f /etc/lw-firstboot.pending ] && [ "$i" -lt 10 ]; do
    sleep 1
    i=$((i + 1))
done
expected="lw-firstboot: $(tr '\n' ' ' </etc/lw-build | sed 's/ *$//')"
lw_expect_grep "$SYSLOG" "$expected"
lw_expect_grep "$SYSLOG" "profile=generic built="
[ ! -f /etc/lw-firstboot.pending ] || lw_fail "marker left after logging"
/etc/init.d/lw-firstboot start
sleep 1
lw_expect_eq "$(grep -c lw-firstboot "$SYSLOG")" 1 "lw-firstboot entries after a normal boot"
echo ok
