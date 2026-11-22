# First boot of a tailscale image with no route and no auth key (SPEC R7 table, R63, R64a, R64b,
# R8a): the interface, the zone that accepts input and rejects output and forward, the uci for
# lw-tailscale, the package's settings with the output out of syslog, no key file and no directory.
# shellcheck source=tests/firstboot/fb-lib
. /fw/tests/firstboot/fb-lib
# shellcheck source=tests/firstboot/ts-lib
. /fw/tests/firstboot/ts-lib
fb_prepare ts-plain
fb_uci_defaults

ts_expect_image 0 192.168.1.0/24 ""
fb_expect system.@system[0].hostname lte-router
fb_expect system.@system[0].log_size 1024
ts_expect_twice
echo ok
