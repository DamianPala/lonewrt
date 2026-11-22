# First boot of a tailscale image that offers its LAN (SPEC R64a, R67, D155, D147, R63b): the
# forwarding from the zone to lan with one translation for Tailscale's addresses, the prefix of
# LAN_IP, the debug level with a log of 1024 KB, and the build identity with the tailscale line in
# the first-boot entry.
# shellcheck source=tests/firstboot/fb-lib
. /fw/tests/firstboot/fb-lib
# shellcheck source=tests/firstboot/ts-lib
. /fw/tests/firstboot/ts-lib
fb_prepare ts-lan
SYSLOG=$LW_TEST/syslog
fb_uci_defaults

ts_expect_image 1 192.168.5.0/24 ""
fb_expect network.lan.ipaddr 192.168.5.1/24
# the name in the account is the host name of the system (R64)
fb_expect system.@system[0].hostname ts-router
# R29c, D147: debug in a tailscale image keeps the persistent log at 1024 KB
fb_expect lonewrt.log.level debug
fb_expect system.@system[0].log_size 1024
ts_expect_twice

# R63b: build.sh appends the package version to /etc/lw-build; the first-start entry carries it
printf 'tailscale=1.104.1-r1\n' >>/etc/lw-build
/etc/init.d/lw-firstboot start
i=0
while [ -f /etc/lw-firstboot.pending ] && [ "$i" -lt 10 ]; do
    sleep 1
    i=$((i + 1))
done
lw_expect_grep "$SYSLOG" "lw-firstboot: version=.* profile=ts-lan .* tailscale=1.104.1-r1"
echo ok
