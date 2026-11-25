#!/bin/sh
. /fw/tests/lib.sh

PATH=/fw/tests/lan6/stubs:$PATH
mkdir -p "$T" /var/run /usr/lib/lw
cp /fw/src/files/usr/lib/lw/lan6.sh /usr/lib/lw/lan6.sh
cp /fw/src/files/etc/init.d/odhcpd /etc/init.d/odhcpd
chmod +x /etc/init.d/odhcpd
hotplug=/fw/src/files/etc/hotplug.d/iface/90-lw-lan6

# Keep rc.common's dispatch. Record the boundary with procd; the signal itself is `ubus call service
# signal`, a stand-in of tests/lan6/stubs (the procd_send_signal wrapper hides the status of ubus).
cat >/lib/functions/procd.sh <<'STUB'
procd_open_service() { :; }
procd_close_service() { :; }
procd_open_instance() { :; }
procd_close_instance() { :; }
procd_lock() { :; }
procd_set_param() { printf '%s\n' "$*" >>"$LW_TEST/procd"; }
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

# R74c: the loss of a served LAN is two signals, the withdrawal advertisement and then the one that
# switches the server off; a change that leaves the server alone is one signal as before
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
export LW_LAN6_WITHDRAW_WAIT=0
ram=/var/run/lw-odhcpd

# serving / lost: what netifd and the kernel say
serving() {
    cat >"$T/wwan.json" <<'JSON'
{"up":true,"l3_device":"wwan0","data":{"cid_4":4,"pdh_4":40,"cid_6":6,"pdh_6":60},"ipv6-prefix":[
  {"address":"2001:db8:2::","mask":64,"assigned":{"lan":{"address":"2001:db8:2::","mask":64}}}]}
JSON
    cat >"$T/lan.json" <<'JSON'
{"up":true,"l3_device":"br-lan","ipv6-prefix-assignment":[
  {"address":"2001:db8:2::","mask":64,"local-address":{"address":"2001:db8:2::1","mask":64}}]}
JSON
    rm -f "$T/wwan_6.json"
    echo '2001:db8:ffff::1 from 2001:db8:2::1 via fe80::1 dev wwan0' >"$T/route"
}
lost() { echo '{"up":false,"l3_device":"wwan0"}' >"$T/wwan.json"; }
# signals: one reload lan6 as the hotplug hook does it; the signal requests it made and its exit status
signals() {
    : >"$T/procd"
    /etc/init.d/odhcpd reload lan6 || echo "init exit $?" >>"$T/procd"
    cat "$T/procd"
}
ra() { uci -q -c "$ram" get dhcp.lan.ra; }
phase() { cat "$ram/phase" 2>/dev/null || echo none; }
pending() { cat "$ram/pending" 2>/dev/null || echo none; }
: >"$T/ubus-script"

/etc/init.d/odhcpd start
lw_expect_eq "$(phase)/$(pending)" off/none "R74c boot: off, nothing pending"
serving
lw_expect_eq "$(signals)" "signal odhcpd" "R74a the prefix arrives: one signal"
lw_expect_eq "$(phase)/$(pending)/$(ra)" active/none/server "R74c applied: serving, nothing pending"
lw_expect_eq "$(signals)" "" "R74e a stable LAN stays quiet"
lost
lw_expect_eq "$(signals)" "signal odhcpd
signal odhcpd" "R74c a loss is a withdrawal and then the final advertisement"
lw_expect_eq "$(phase)/$(pending)/$(ra)" off/none/disabled "R74c server off after the loss"
lw_expect_eq "$(signals)" "" "R74c nothing more after the loss"
serving
lw_expect_eq "$(signals)" "signal odhcpd" "R74c the return is one signal"
lw_expect_eq "$(phase)/$(pending)" active/none "R74c back to serving"

# R74c: a signal that did not reach odhcpd is not an applied change. The first request of a loss
# fails: the RAM copy has the withdrawal config, the change stays pending, and the next run signals
# although the bytes match.
lost
echo fail >"$T/ubus-script"
lw_expect_eq "$(signals)" "signal odhcpd failed
init exit 1" "R74c the withdrawal request failed: the init script says so, no second phase"
lw_expect_eq "$(phase)/$(pending)/$(ra)" active/w/server "R74c failed withdrawal stays pending (config installed)"
lw_expect_eq "$(signals)" "signal odhcpd
signal odhcpd" "R74c the next run repeats the withdrawal and finishes the loss"
lw_expect_eq "$(phase)/$(pending)/$(ra)" off/none/disabled "R74c loss completed"

# the final request fails (the first one goes out)
serving
signals >/dev/null
lost
printf 'ok\nfail\n' >"$T/ubus-script"
lw_expect_eq "$(signals)" "signal odhcpd
signal odhcpd failed
init exit 1" "R74c the final request failed"
lw_expect_eq "$(phase)/$(pending)/$(ra)" w/off/disabled "R74c odhcpd still runs the withdrawal config; off pending"
lw_expect_eq "$(signals)" "signal odhcpd" "R74c one more signal, though the RAM copy already says off"
lw_expect_eq "$(phase)/$(pending)" off/none "R74c confirmed"
lw_expect_eq "$(signals)" "" "R74c and then quiet"

# a return whose request failed
serving
echo fail >"$T/ubus-script"
lw_expect_eq "$(signals)" "signal odhcpd failed
init exit 1" "R74c the return's request failed"
lw_expect_eq "$(phase)/$(pending)/$(ra)" off/active/server "R74c the daemon may still be quiet while the file serves"
lw_expect_eq "$(signals)" "signal odhcpd" "R74c the return is repeated"
lw_expect_eq "$(phase)/$(pending)" active/none "R74c serving, confirmed"

# procd can have a service entry before or after it holds an instance to signal.
lost
: >"$T/procd-no-instance"
lw_expect_eq "$(signals)" "signal odhcpd failed
init exit 1" "R74c an empty service did not receive a signal"
lw_expect_eq "$(phase)/$(pending)" active/w "R74c the withdrawal is still owed"
rm -f "$T/procd-no-instance"
serving
signals >/dev/null

# the caller killed right after the rename: configure ran, nobody signalled
lost
lw_expect_eq "$(sh -c '. /usr/lib/lw/lan6.sh; lan6_configure event')" withdraw "R74c configure alone installs the withdrawal"
lw_expect_eq "$(pending)" w "R74c the mark is there"
lw_expect_eq "$(signals)" "signal odhcpd
signal odhcpd" "R74c the next run does both signals"
lw_expect_eq "$(phase)/$(pending)" off/none "R74c completed"

# the same with a real SIGKILL right after the rename (the stub mv of tests/lan6/killstub): the RAM
# copy already has the new bytes, so only the mark that went first makes the next run signal
serving
signals >/dev/null
lost
: >"$T/kill-after-mv"
# the trailing ':' keeps ash from running the subshell in the process of sh -c itself, which the kill would take
PATH=/fw/tests/lan6/killstub:$PATH sh -c '. /usr/lib/lw/lan6.sh; lan6_configure event; :' >/dev/null 2>&1
[ ! -e "$T/kill-after-mv" ] || lw_fail "R74c the stub mv did not kill the run"
lw_expect_eq "$(phase)/$(pending)/$(ra)" active/w/server "R74c killed after the rename: the mark of the withdrawal is there"
lw_expect_eq "$(signals)" "signal odhcpd
signal odhcpd" "R74c the next run signals although the bytes match"
lw_expect_eq "$(phase)/$(pending)/$(ra)" off/none/disabled "R74c completed after the kill"
lw_expect_eq "$(ls -d "$ram"/stage.* 2>/dev/null)" "" "R74c the stage of the killed run is gone"

# A prefix that returns before a pending withdrawal was installed leaves odhcpd serving.
serving
signals >/dev/null
lost
: >"$T/kill-before-mv"
PATH=/fw/tests/lan6/killstub:$PATH sh -c '. /usr/lib/lw/lan6.sh; lan6_configure event; :' >/dev/null 2>&1
[ ! -e "$T/kill-before-mv" ] || lw_fail "R74c the stub mv did not kill the run before the move"
lw_expect_eq "$(phase)/$(pending)/$(ra)" active/w/server "R74c killed before the rename"
serving
lw_expect_eq "$(signals)" "signal odhcpd" "R74c replay uses the recovered prefix"
lw_expect_eq "$(phase)/$(pending)" active/none "R74c the recovered prefix is still active"
lost
lw_expect_eq "$(signals)" "signal odhcpd
signal odhcpd" "R74c the next loss still sends a withdrawal"

# a withdrawal killed during its wait: the first request went out, the final one is still owed
serving
signals >/dev/null
lost
sh -c '. /usr/lib/lw/lan6.sh
    lan6_configure event >/dev/null; lan6_applied'
lw_expect_eq "$(phase)/$(pending)/$(ra)" w/off/server "R74c the withdrawal advertisement is out, the final one is owed"
lw_expect_eq "$(signals)" "signal odhcpd" "R74c the next run sends the final advertisement"
lw_expect_eq "$(phase)/$(ra)" off/disabled "R74c completed without a next event of the session"

# a status that cannot be read in the wait: the final advertisement stays owed
serving
signals >/dev/null
lost
printf 'ok\n' >"$T/ubus-script"
sh -c '. /usr/lib/lw/lan6.sh
    lan6_configure event >/dev/null; lan6_applied'
rm -f "$T/wwan.json"
lw_expect_eq "$(signals)" "init exit 1" "R74c unreadable status with the final advertisement owed: nothing signalled"
lw_expect_eq "$(phase)/$(pending)" w/off "R74c still owed"
lost
lw_expect_eq "$(signals)" "signal odhcpd" "R74c status readable again: the final advertisement goes out"
lw_expect_eq "$(phase)/$(pending)/$(ra)" off/none/disabled "R74c completed"

# an unreadable status is unknown, not a loss
serving
signals >/dev/null
rm -f "$T/wwan.json"
lw_expect_eq "$(signals)" "init exit 1" "R74c an unreadable wwan status keeps the LAN as it is (exit 1: not reconciled)"
lw_expect_eq "$(phase)/$(ra)" active/server "R74c still serving"
echo 'not json' >"$T/wwan.json"
lw_expect_eq "$(signals)" "init exit 1" "R74c a garbled wwan status keeps the LAN as it is"
serving
rm -f "$T/lan.json"
lw_expect_eq "$(signals)" "init exit 1" "R74c an unreadable lan status keeps the LAN as it is"
lw_expect_eq "$(phase)/$(ra)" active/server "R74c still serving, lan unknown"
serving
lost
lw_expect_eq "$(signals)" "signal odhcpd
signal odhcpd" "R74c a status that says down is a loss"

# the stage of a run that was killed is cleaned by the next run
mkdir "$ram/stage.dead"
echo x >"$ram/stage.dead/lw_odhcpd"
signals >/dev/null
lw_expect_eq "$(ls -d "$ram"/stage.* 2>/dev/null)" "" "R74c a killed run's stage is removed"
echo ok
