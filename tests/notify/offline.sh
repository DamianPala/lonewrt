# R34 scenario 2 and R34a: without internet 2 SMS wait in the queue on flash, survive a reboot and
# go out once each, in order, as soon as Telegram answers. R34c: one syslog entry when sending
# stops working and one when it works again. The wwan hotplug sends the queue at once.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup ''
passes 2

echo down >"$G/net"
sms_in 0 +38200000001 '11/07/26 12:00:00' 'first while offline'
sms_in 1 +38200000002 '11/07/26 12:00:30' 'second while offline'
passes 5
expect_sent 0
lw_expect_eq "$(find /etc/lw-notify/queue -type f | wc -l)" 2 "queued messages"
lw_expect_eq "$(grep -c 'lw-notify: Telegram unreachable' "$T/syslog")" 1 "unreachable entries"

lw_reboot_sim
passes 2
expect_sent 0
echo up >"$G/net"
pass
expect_sent 2
lw_expect_eq "$(sent_text 1)" "✉️ +38200000001 · 7 Nov 12:00

first while offline" "first queued message (no ntpd after the reboot: the plain date)"
case $(sent_text 2) in
    *'second while offline') ;;
    *) lw_fail "second message: $(sent_text 2)" ;;
esac
lw_expect_eq "$(grep -c 'lw-notify: Telegram reachable again' "$T/syslog")" 1 "reachable entries"
passes 4
lw_reboot_sim
passes 4
expect_sent 2
# unreachable before and after the reboot (the link state lives in RAM), reachable once
lw_expect_eq "$(grep -c lw-notify "$T/syslog")" 3 "syslog entries in total"

# hotplug: the queue goes out when wwan comes up, without waiting for a pass
echo down >"$G/net"
sms_in 2 +38200000003 '11/07/26 13:00:00' 'sent by the hotplug'
passes 2
expect_sent 2
echo up >"$G/net"
t0=$(date +%s)
ACTION=ifup INTERFACE=wwan sh /etc/hotplug.d/iface/95-lw-notify
[ "$(elapsed_since "$t0")" -le 1 ] || lw_fail "hotplug did not return at once"
i=0
while [ "$(sent)" -lt 3 ] && [ "$i" -lt 10 ]; do
    sleep 1
    i=$((i + 1))
done
expect_sent 3
expect_last 'sent by the hotplug'
# other interfaces and events do nothing
calls=$(wc -l <"$G/calls")
ACTION=ifdown INTERFACE=wwan sh /etc/hotplug.d/iface/95-lw-notify
ACTION=ifup INTERFACE=lan sh /etc/hotplug.d/iface/95-lw-notify
sleep 1
lw_expect_eq "$(wc -l <"$G/calls")" "$calls" "API calls after other hotplug events"
pass
expect_sent 3
echo ok
