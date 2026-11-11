# First boot of a full-profile image built from tests/build/fixtures/fake-full.conf (SPEC R7 table
# full-profile column, R11c band target, R31 tunnel, R13 APN from the profile, SSH keys).
# shellcheck source=tests/firstboot/fb-lib
. /fw/tests/firstboot/fb-lib
fb_prepare fake-full
fb_uci_defaults

fb_expect network.lan.ipaddr 192.168.77.1/24
fb_expect system.@system[0].hostname fakelw-q7x9
fb_expect system.@system[0].zonename Europe/Berlin

for r in radio0 radio1; do
    fb_expect wireless.$r.country DE
    fb_expect wireless.default_$r.ssid FakeLwSsid-q7x9
    fb_expect wireless.default_$r.key fake-wifi-key-q7x9
    fb_expect wireless.default_$r.encryption psk2
done
fb_expect wireless.radio0.channel 5
fb_expect wireless.radio0.htmode HT40
fb_expect wireless.radio1.channel 100
fb_expect wireless.radio1.htmode VHT80

fb_expect network.wwan.apn fake.apn.q7x9
fb_expect network.wwan.auth pap
fb_expect network.wwan.username fakeuser-q7x9
fb_expect network.wwan.password fakepass-q7x9
fb_expect network.wwan.modes lte
fb_expect lonewrt.modem.bands 1,3,8,20,28,32

fb_expect network.wg0.disabled "<unset>"
# joined from parts like tests/build/lib.bash does, so no whole private-key shape sits in a file
fb_expect network.wg0.private_key "RkFLRS13Zy1wcml2YXRl""LWtleS1xN3g5LTAxMjM0NTY="
fb_expect network.wg0.addresses 10.99.77.24/32
fb_expect network.wg_server.public_key RkFLRS13Zy1wZWVyLXB1YmxpYy1rZXktcTd4OS0wMTI=
fb_expect network.wg_server.endpoint_host vpn.fake-q7x9.example
fb_expect network.wg_server.endpoint_port 51999
fb_expect network.wg_server.persistent_keepalive 23
fb_expect network.wg_server.allowed_ips 10.99.77.0/24
fb_expect network.wg_server.route_allowed_ips 1
fb_expect firewall.vpn.network wg0

# R42: the heartbeat address is in the root-only config, and the cron line calls the script every 5 min
fb_expect lonewrt.heartbeat.url "https://hc-ping.fake-q7x9.example/FAKEhcping-q7x9-0001"
lw_expect_eq "$(find /etc/config/lonewrt -perm 600)" /etc/config/lonewrt "mode of /etc/config/lonewrt"
lw_expect_eq "$(grep -c lw-heartbeat /etc/crontabs/root)" 1 "heartbeat lines in the crontab"
grep -qxF '*/5 * * * * /usr/sbin/lw-heartbeat' /etc/crontabs/root || lw_fail "no heartbeat cron line"
! grep -q 'hc-ping' /etc/crontabs/root || lw_fail "the heartbeat address is in the crontab"

# R29c: the debug level of the profile: the level in uci and a persistent log of 2 MB before it rotates
fb_expect lonewrt.log.level debug
fb_expect system.@system[0].log_size 2048
fb_expect system.@system[0].log_buffer_size 1024
fb_expect system.@system[0].log_file /root/openwrt.log

# R14a: the profile's delay is the period of the soft restart of wwan
fb_expect watchcat.wwan_soft.period 180

# R46: the SMS admin list lands verbatim in the same root-only config, and nowhere else
fb_expect lonewrt.notify.sms_admins "+15550100123,15550100456"
! grep -rqF 15550100123 /etc/crontabs /etc/rc.d /etc/init.d 2>/dev/null ||
    lw_fail "the SMS admins are outside /etc/config/lonewrt"

grep -qF "root:\$6\$fakesaltq7x9\$" /etc/shadow || lw_fail "root hash is not the profile's"
for f in authorized_keys dropbear_ed25519_host_key dropbear_rsa_host_key; do
    cmp -s "/etc/dropbear/$f" "/fw/tests/build/fixtures/fake-full/$f" || lw_fail "/etc/dropbear/$f"
done

# R8a for the full profile too
first=$(fb_state)
fb_uci_defaults
lw_expect_eq "$(fb_state)" "$first" "state after a second uci-defaults run"
fb_expect uhttpd.main.redirect_https 1
echo ok
