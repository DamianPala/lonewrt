# R7d, R14b, D181: after a flash that keeps settings, the watchcat file of the old release comes back
# with `wwan_soft` (its own period) and no lw_family_check; the first start gives that entry the option
# and leaves every other entry, and an option the owner set, as it was. A clean flash has the option
# from the image's own file (generic.sh and full.sh also look at the period).
# shellcheck source=tests/firstboot/fb-lib
. /fw/tests/firstboot/fb-lib
fb_prepare generic

# the image's own file: the option is there before the first start, so a clean flash has it
fb_expect watchcat.wwan_soft.lw_family_check 1

# a kept 0.6.1 file: period 300, no option, one more entry of the owner
cat >/etc/config/watchcat <<'EOF'
config watchcat 'wwan_soft'
	option mode 'restart_iface'
	option interface '@wwan'
	option pinghosts '8.8.8.8 1.1.1.1'
	option pingperiod '60'
	option period '300'
	option pingsize 'standard'
	option addressfamily 'ipv4'
	option reset_failure_timer '1'

config watchcat 'owner_reboot'
	option mode 'ping_reboot'
	option interface 'wwan0'
	option period '6h'
	option pinghosts '9.9.9.9'
	option forcedelay '30'
EOF
fb_expect watchcat.wwan_soft.lw_family_check "<unset>"
before_other=$(uci show watchcat.owner_reboot)
fb_uci_defaults
fb_expect watchcat.wwan_soft.lw_family_check 1
fb_expect watchcat.wwan_soft.period 300
fb_expect watchcat.wwan_soft.mode restart_iface
fb_expect watchcat.wwan_soft.pingperiod 60
fb_expect watchcat.wwan_soft.addressfamily ipv4
lw_expect_eq "$(uci show watchcat.owner_reboot)" "$before_other" "the other entry of the owner"
lw_expect_eq "$(uci show watchcat | grep -c lw_family_check)" 1 "entries with the option"

# a second run (a first start cut by a power loss, R8a) ends in the same state
state=$(uci export watchcat)
fb_uci_defaults
lw_expect_eq "$(uci export watchcat)" "$state" "watchcat file after a second run"

# an owner who set 0 keeps it; a file without wwan_soft gets no entry made for it
printf "config watchcat 'wwan_soft'\n\toption mode 'restart_iface'\n\toption period '200'\n\toption lw_family_check '0'\n" >/etc/config/watchcat
fb_uci_defaults
fb_expect watchcat.wwan_soft.lw_family_check 0
printf "config watchcat 'mine'\n\toption mode 'ping_reboot'\n\toption period '1h'\n" >/etc/config/watchcat
fb_uci_defaults
lw_expect_eq "$(uci show watchcat | grep -c lw_family_check || true)" 0 "options in a file without wwan_soft"
fb_expect watchcat.wwan_soft "<unset>"
