# First boot of a debug-level image without Tailscale (SPEC R29c, R63): the persistent log rotates at
# 2048 KB, and nothing of Tailscale is there.
# shellcheck source=tests/firstboot/fb-lib
. /fw/tests/firstboot/fb-lib
# shellcheck source=tests/firstboot/ts-lib
. /fw/tests/firstboot/ts-lib
fb_prepare debug-plain
fb_uci_defaults

fb_expect lonewrt.log.level debug
fb_expect system.@system[0].log_size 2048
fb_expect system.@system[0].log_buffer_size 1024
ts_expect_absent
echo ok
