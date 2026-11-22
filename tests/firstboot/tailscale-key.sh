# First boot of a tailscale image with an auth key and no route (SPEC R64b, R66a, R8a): the key is
# in /etc/tailscale/lw-authkey, readable by root only, and in no other file; no forwarding or
# translation for the LAN.
# shellcheck source=tests/firstboot/fb-lib
. /fw/tests/firstboot/fb-lib
# shellcheck source=tests/firstboot/ts-lib
. /fw/tests/firstboot/ts-lib
fb_prepare ts-key
fb_uci_defaults

# joined from parts like tests/build/lib.bash does
ts_expect_image 0 192.168.1.0/24 "tskey-auth-""kTESTq7x9CNTRL-q7x9fakeauthkeyq7x9"
ts_expect_twice
echo ok
