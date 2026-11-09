# R30, D19: the redirect from HTTP to HTTPS is set on the uhttpd section the package ships, and only
# there: an image without LuCI (no /etc/config/uhttpd) gets no uhttpd file or section from the first
# boot, and the second run of the script changes nothing.
# shellcheck source=tests/firstboot/fb-lib
. /fw/tests/firstboot/fb-lib
fb_prepare generic
fb_expect uhttpd.main.redirect_https 0
fb_uci_defaults
fb_expect uhttpd.main.redirect_https 1
before=$(uci export uhttpd)
fb_uci_defaults
lw_expect_eq "$(uci export uhttpd)" "$before" "uhttpd after a second run"

rm -f /etc/config/uhttpd
rm -rf /tmp/.uci
fb_uci_defaults
fb_expect uhttpd.main "<unset>"
[ ! -e /etc/config/uhttpd ] || lw_fail "the first boot created /etc/config/uhttpd"
echo ok
