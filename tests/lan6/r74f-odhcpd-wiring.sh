#!/bin/sh
. /fw/tests/lib.sh

mkdir -p "$T" /var/run /usr/lib/lw
cp /fw/src/files/usr/lib/lw/lan6.sh /usr/lib/lw/lan6.sh
cp /fw/src/files/etc/init.d/odhcpd /etc/init.d/odhcpd
chmod +x /etc/init.d/odhcpd
hotplug=/fw/src/files/etc/hotplug.d/iface/90-lw-lan6

# Keep rc.common's dispatch. Record just the boundary with procd.
cat >/lib/functions/procd.sh <<'STUB'
procd_open_service() { :; }
procd_close_service() { :; }
procd_open_instance() { :; }
procd_close_instance() { :; }
procd_lock() { :; }
procd_set_param() { printf '%s\n' "$*" >>"$LW_TEST/procd"; }
procd_send_signal() { printf 'signal %s\n' "$*" >>"$LW_TEST/procd"; }
STUB

: >"$T/procd"
/etc/init.d/odhcpd start
lw_expect_eq "$(cat "$T/procd")" "command /usr/sbin/odhcpd -c /var/run/lw-odhcpd
respawn" "R74e start with RAM config and respawn"
uci -q -c /var/run/lw-odhcpd get dhcp.lan >/dev/null

mv /etc/config/dhcp "$T/dhcp"
: >"$T/procd"
/etc/init.d/odhcpd start 2>"$T/error"
lw_expect_eq "$(cat "$T/procd")" "command /usr/sbin/odhcpd
respawn" "R74b start falls back on failed RAM copy"
mv "$T/dhcp" /etc/config/dhcp

: >"$T/procd"
/etc/init.d/odhcpd reload lan6
lw_expect_eq "$(cat "$T/procd")" "" "R74e unchanged LAN event stays quiet"
/etc/init.d/odhcpd reload
lw_expect_eq "$(cat "$T/procd")" "signal odhcpd" "ordinary reload retains SIGHUP"

action=ifup
for iface in wwan wwan_4 wwan_6 wwan_6_4 lan guest; do
    uci set "dhcp.lan.leasetime=${iface}-fixture"
    uci commit dhcp
    : >"$T/procd"
    ACTION=$action INTERFACE=$iface sh "$hotplug"
    expected="signal odhcpd"
    [ "$iface" != guest ] || expected=
    lw_expect_eq "$(cat "$T/procd")" "$expected" "R74f $action on $iface"
    : >"$T/procd"
    ACTION=$action INTERFACE=$iface sh "$hotplug"
    lw_expect_eq "$(cat "$T/procd")" "" "R74e unchanged $action on $iface"
    case $action in
        ifup) action=ifupdate ;;
        ifupdate) action=ifdown ;;
        ifdown) action=ifup ;;
    esac
done
echo ok
