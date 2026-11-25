# R76, R76b, R76c, D186: the hotplug dispatch of lw-clat-check lives in 90-lw-lan6 (no file of its own:
# hotplug-call runs every file in a subshell, a fork per event on every session) and decides with
# shell builtins alone. On the owner's IPv4-only router, on a dual-stack session with an IPv6 child
# (whatever the modem's report said) and on every other event it starts nothing; an IPv6-only
# session's child, the parent of a session while a translation exists, and the end of such a session
# start the check, detached.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/clat/helpers.inc
. /fw/tests/clat/helpers.inc

hotplug=/fw/src/files/etc/hotplug.d/iface/90-lw-lan6
real=/usr/sbin/lw-clat-check
cl_setup
cp "$real" "$C/real-check"
printf '#!/bin/sh\necho "$*" >>"$LW_TEST/clat/check-calls"\n' >"$real"
# the rest of the file is the existing odhcpd reload of R74f: a recorder in its place
mkdir -p /etc/init.d
printf '#!/bin/sh\necho "$*" >>"$LW_TEST/clat/odhcpd-calls"\n' >/etc/init.d/odhcpd
chmod 755 /etc/init.d/odhcpd
hot() {
    ACTION=$1 INTERFACE=$2 LW_CLAT_DIR=$CL_DIR sh "$hotplug"
    # the check is detached: give it a moment
    /bin/sleep 1
}
calls() { cat "$C/check-calls" 2>/dev/null || :; }

# the session is not IPv6-only (no mark of one): no event starts anything. The mark of an
# earlier IPv6-only session that a session with native IPv4 and no child left is no matter here,
# since no child comes up; the dual-stack session with a child has cleared it (qmi.sh, tests/qmi)
rm -f "$CL_DIR/v6only"
for ev in 'ifup wwan' 'ifup wwan_4' 'ifup wwan_6' 'ifup wwan_6_4' 'ifdown wwan' 'ifdown wwan_6' \
    'ifupdate wwan_6' 'ifup lan' 'ifup wan' 'ifdown lan' 'ifup loopback'; do
    # shellcheck disable=SC2086  # the event is two words
    hot $ev
done
lw_expect_eq "$(calls)" "" "no mark: events that start nothing"
lw_expect_eq "$(grep -c . "$C/odhcpd-calls")" 9 "the existing odhcpd reload still runs for wwan, wwan_* and lan events"
[ ! -e "$CL_DIR/lock" ] || lw_fail "no mark: the check left a lock"

# a dual-stack session with an IPv6 child (dhcpv6=1, or a modem report that could not be used):
# qmi.sh emptied the stale record, the child comes up, nothing starts
lw_session dual
: >"$CL_DIR/v6only"
printf '{"up":true,"l3_device":"wwan0","ipv6-address":[{"address":"2001:db8:1::2","mask":64}],"dns-server":["%s"]}\n' \
    "$DNS_ADDR" >"$T/ifstatus/wwan_6.json"
hot ifup wwan_6
hot ifup wwan
hot ifup wwan_4
lw_expect_eq "$(calls)" "" "dual stack with an IPv6 child: nothing starts"

# an IPv6-only session: the child's ifup starts the check (new), the parent's does not
cl_session_mark s1
hot ifup wwan
lw_expect_eq "$(calls)" "" "IPv6-only, ifup wwan, no translation yet: nothing starts"
hot ifup wwan_6
lw_expect_eq "$(calls)" "new" "IPv6-only, ifup wwan_6: the check starts"
: >"$C/check-calls"

# while a translation exists (its mark): the parent's ifup (a new session or a native one) starts the
# check, so does the end of the session, and so does an update of the child (the operator renumbering
# the link in place moves its address: R76c); with no translation an update starts nothing
rm -f "$CL_DIR/v6only"
mkdir -p "$CL_DIR"
: >"$CL_DIR/active"
hot ifup wwan
lw_expect_eq "$(calls)" "new" "a translation exists, ifup wwan"
: >"$C/check-calls"
hot ifdown wwan
lw_expect_eq "$(calls)" "down" "a translation exists, ifdown wwan"
: >"$C/check-calls"
hot ifupdate wwan_6
lw_expect_eq "$(calls)" "update" "a translation exists, ifupdate wwan_6"
: >"$C/check-calls"
hot ifupdate wwan
hot ifupdate wwan_6_4
hot ifupdate lan
lw_expect_eq "$(calls)" "" "a translation exists, the updates of other interfaces start nothing"
rm -f "$CL_DIR/active"
hot ifdown wwan
hot ifupdate wwan_6
lw_expect_eq "$(calls)" "" "no translation, ifdown wwan and ifupdate wwan_6: nothing starts"

# builtins only: what the dispatch runs before the existing reload is `case` and `[` and nothing else
# (a trace of an event that starts nothing, minus the reload that was there before)
for ev in 'ifup wwan' 'ifup wwan_6' 'ifup wwan_4' 'ifup wwan_6_4' 'ifup lan' 'ifdown wwan' 'ifdown wwan_6' 'ifdown lan' \
    'ifupdate wwan_6' 'ifupdate wwan' 'ifupdate wwan_6_4'; do
    # shellcheck disable=SC2086  # the event is two words
    set -- $ev
    trace=$(ACTION=$1 INTERFACE=$2 LW_CLAT_DIR=$CL_DIR sh -x "$hotplug" 2>&1 | grep '^+' | grep -v -e '^+ case' -e '^+ \[ ' -e "^+ '\\[' " || :)
    case $2 in
        wwan | wwan_* | lan) want="+ d=$CL_DIR
+ /etc/init.d/odhcpd reload lan6" ;;
        *) want="+ d=$CL_DIR" ;;
    esac
    lw_expect_eq "$trace" "$want" "trace of $ev with no mark: only builtins and the old reload"
done

cp "$C/real-check" "$real"
chmod 755 "$real"
echo ok
