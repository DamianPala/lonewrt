# R14b, R14e, D195: the image's init script starts the entry `wwan_soft` with the hook variable and no
# other entry: not a second entry of the owner for `wwan`, not another mode, not an entry whose option
# is 0. Apart from that variable the service it hands to procd is the stock init script's, so the
# period, the hosts, the ping period and the timer reset reach the worker as they always did. The init
# scripts run for real (the package's own and the image's) with a stand-in `ubus` that records the
# service they set.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/watchcat/helpers.inc
. /fw/tests/watchcat/helpers.inc
wc_setup
mkdir -p /var/lock

config() {
    sed 's/@LINK_RESTART_AFTER_S@/180/' /fw/src/files/etc/config/watchcat >/etc/config/watchcat
    cat >>/etc/config/watchcat <<'EOF'

config watchcat 'owner'
	option mode 'restart_iface'
	option interface '@wwan'
	option period '300'
	option pinghosts '9.9.9.9'

config watchcat 'owner_script'
	option mode 'run_script'
	option interface '@wwan'
	option period '300'
	option script '/bin/true'

config watchcat 'owner_reboot'
	option mode 'ping_reboot'
	option interface 'wwan0'
	option period '1h'
	option pinghosts '9.9.9.9'

config watchcat 'owner_off'
	option mode 'restart_iface'
	option interface '@wwan'
	option period '400'
	option lw_family_check '0'
EOF
}

# service FILE: the service the init script at FILE sets, as one line
service() {
    rm -f "$T/ubus-calls"
    cp "$1" /etc/init.d/wc-under-test
    /etc/init.d/wc-under-test start >/dev/null 2>&1
    grep '^call service set' "$T/ubus-calls" | sed 's/"name": "wc-under-test", "script": "[^"]*", //'
}

config
stock=$(service /wc-stock/etc/init.d/watchcat)
image=$(service /wc-overlay/etc/init.d/watchcat)
[ -n "$stock" ] && [ -n "$image" ] || lw_fail "an init script set no service"

# only wwan_soft gets the variable, once
lw_expect_eq "$(printf '%s\n' "$image" | grep -o 'LW_WATCHCAT_FAMILY' | wc -l)" 1 "entries with the hook variable"
printf '%s\n' "$image" | grep -q '"watchcat_wwan_soft": { "command": \[[^]]*\], "env": { "LW_WATCHCAT_FAMILY": "1" }' ||
    lw_fail "wwan_soft has no hook variable: $image"
# nothing else differs from stock: the same service with that one fragment taken out
lw_expect_eq "$(printf '%s\n' "$image" | sed 's/ "env": { "LW_WATCHCAT_FAMILY": "1" },//')" "$stock" \
    "the service of the image's init script without the variable, against stock's"
# the worker gets what it always did: period 180, both addresses, 60 s, the timer reset
printf '%s\n' "$image" | grep -q '"restart_iface", "180", "8.8.8.8 1.1.1.1", "60", "standard", "@wwan", "null", "0", "ipv4", "", "1"' ||
    lw_fail "the arguments of wwan_soft changed: $image"

# the option set only on an entry that is not restart_iface does nothing: the other modes ignore it
cat >>/etc/config/watchcat <<'EOF'

config watchcat 'owner_set'
	option mode 'ping_reboot'
	option interface 'wwan0'
	option period '1h'
	option lw_family_check '1'
EOF
image=$(service /wc-overlay/etc/init.d/watchcat)
lw_expect_eq "$(printf '%s\n' "$image" | grep -o 'LW_WATCHCAT_FAMILY' | wc -l)" 1 "entries with the hook variable with the option on a reboot entry"

# the entry without the option, as an old 0.6.1 file has it: stock
uci -q delete watchcat.wwan_soft.lw_family_check
uci commit watchcat
image=$(service /wc-overlay/etc/init.d/watchcat)
lw_expect_eq "$(printf '%s\n' "$image" | grep -c LW_WATCHCAT_FAMILY || true)" 0 "hook variable without the option"
