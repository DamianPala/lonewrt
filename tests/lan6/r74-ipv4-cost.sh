#!/bin/sh
# R74f, owner rule: a router with an IPv4-only session pays nothing for the IPv6 LAN withdrawal. The hook of
# an IPv4-only `ifup wwan` runs the same commands, through the real init script and lan6.sh, as the
# stock files of tests/lan6/stock (byte copies of the image before the withdrawal, 696c615): every
# external command is counted by a wrapper, and no command of the L1 files may exceed the stock count.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh

PATH=/fw/tests/lan6/stubs:$PATH
mkdir -p "$T" /var/run /usr/lib/lw
hotplug=/fw/src/files/etc/hotplug.d/iface/90-lw-lan6

cat >/lib/functions/procd.sh <<'STUB'
procd_open_service() { :; }
procd_close_service() { :; }
procd_open_instance() { :; }
procd_close_instance() { :; }
procd_lock() { :; }
procd_set_param() { :; }
procd_send_signal() { echo "signal $*" >>"$LW_TEST/procd"; }
STUB

cat >/etc/config/network <<'UCI'
config interface 'lan'
    option proto 'static'
    list ipaddr '192.0.2.1/24'
    option ip6assign '64'
    option lw_ipv6 '1'
UCI
cat >/etc/config/dhcp <<'UCI'
config dhcp 'lan'
    option interface 'lan'
    option ra 'disabled'
    option dhcpv6 'disabled'
    option dhcpv4 'server'
UCI
# the IPv4-only session of the owner: one call, no IPv6 data
echo '{"up":true,"l3_device":"wwan0","uptime":100,"data":{"cid_4":4,"pdh_4":40}}' >"$T/wwan.json"
echo '{"up":true,"l3_device":"br-lan"}' >"$T/lan.json"
: >"$T/wwan_6.json"

# wrappers that count the commands
mkdir -p /tmp/count
for c in uci jsonfilter ifstatus ip cmp mktemp mkdir ln sed rm rmdir mv flock timeout ubus cat date \
    readlink basename sleep sh; do
    real=$(command -v "$c" 2>/dev/null) || continue
    printf '#!/bin/sh\necho %s >>"$LW_TEST/cmds"\nexec %s "$@"\n' "$c" "$real" >"/tmp/count/$c"
    chmod +x "/tmp/count/$c"
done

# run VERSION: install the files, boot, then three IPv4-only events; the commands of the last one
run() {
    if [ "$1" = stock ]; then
        cp /fw/tests/lan6/stock/lan6.sh /usr/lib/lw/lan6.sh
        cp /fw/tests/lan6/stock/odhcpd /etc/init.d/odhcpd
    else
        cp /fw/src/files/usr/lib/lw/lan6.sh /usr/lib/lw/lan6.sh
        cp /fw/src/files/etc/init.d/odhcpd /etc/init.d/odhcpd
    fi
    chmod +x /etc/init.d/odhcpd
    find /var/run -maxdepth 1 -name 'lw-odhcpd*' -exec rm -r {} +
    /etc/init.d/odhcpd start
    for _ in 1 2 3; do
        : >"$T/cmds"
        : >"$T/procd"
        PATH=/tmp/count:$PATH ACTION=ifup INTERFACE=wwan sh "$hotplug"
    done
    lw_expect_eq "$(cat "$T/procd")" "" "$1: a steady IPv4-only event sends no signal"
    sort "$T/cmds" | uniq -c | sed 's/^ *//' >"$T/count.$1"
}

run stock
run l1
echo "stock:" && cat "$T/count.stock"
echo "l1:" && cat "$T/count.l1"
lw_expect_eq "$(cat "$T/count.l1")" "$(cat "$T/count.stock")" "R74f IPv4-only ifup wwan runs the stock commands"
[ "$(grep -c uci "$T/cmds")" -ge 1 ] || lw_fail "the wrappers did not see uci: the count proves nothing"
echo ok
