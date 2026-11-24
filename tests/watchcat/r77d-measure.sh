# R77d, R14g, D198: the traffic measure (traffic.sh) on its own. It reads the IPv6 counters of the
# session's device from /proc/net/dev_snmp6/<dev> and says traffic, quiet or unknown:
#   traffic  at least 4 packets in and 4 out since the sample, ICMPv6 taken off (advertisements,
#            neighbour discovery, the probes); IPv4 is not in these counters at all
#   quiet    a valid sample, less than that: the only evidence of silence
#   unknown  no sample before, no counters, a counter that went back, a sample of another session or
#            device, or one older than the age limit
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
lw_setup
# shellcheck source=src/files/usr/lib/lw/common.sh
. /usr/lib/lw/common.sh
# shellcheck source=src/files/usr/lib/lw/probe.sh
. /usr/lib/lw/probe.sh
# shellcheck source=src/files/usr/lib/lw/traffic.sh
. /usr/lib/lw/traffic.sh

MAXAGE=150
SNMP=$LW_TRAFFIC_SNMP6
# a session born at second BIRTH of the uptime clock: netifd's uptime of wwan grows with the clock
BIRTH=700
lw_now() { cut -d. -f1 "$LW_UPTIME_FILE"; }
session() {
    BIRTH=$1
    lw_session v6
    sed -i 's/^{/{"uptime":0,/' "$T/ifstatus/wwan.json"
}
tick() {
    sed -i "s/\"uptime\":[0-9]*/\"uptime\":$(($(lw_now) - BIRTH))/" "$T/ifstatus/wwan.json"
}
# measure DEVICE: one check of the session as it is now, the state in $LW_T_STATE, the sample just
# taken in $LW_T_BASE (the next check passes it back)
measure() {
    tick
    lw_probe_session
    rc=0
    lw_traffic_measure "${1:-wwan0}" "$MAXAGE" "$LW_T_BASE" || rc=$?
}
expect() {
    lw_expect_eq "$LW_T_STATE" "$1" "state: $2"
    case $1 in traffic) lw_expect_eq "$rc" 0 "exit: $2" ;; *) lw_expect_eq "$rc" 1 "exit: $2" ;; esac
}
fresh() {
    rm -rf "$SNMP"
    LW_T_BASE=''
    lw_uptime_set 1000
    session 700
}

# no counters at all: unknown, and nothing kept as a baseline
fresh
measure
expect unknown "no file"
lw_expect_eq "$LW_T_BASE" "" "baseline without counters"

# the first sample has no baseline; then traffic, then quiet in every way
snmp6-add wwan0 0 0 0 0
measure
expect unknown "first sample"
lw_uptime_add 60
snmp6-add wwan0 60 60 0 0
measure
expect traffic "traffic both ways"
lw_uptime_add 60
snmp6-add wwan0 4 4 0 0
measure
expect traffic "exactly the minimum"
lw_uptime_add 60
snmp6-add wwan0 3 4 0 0
measure
expect quiet "one packet in under the minimum"
lw_uptime_add 60
snmp6-add wwan0 4 3 0 0
measure
expect quiet "one packet out under the minimum"
lw_uptime_add 60
snmp6-add wwan0 60 0 0 0
measure
expect quiet "in only"
lw_uptime_add 60
snmp6-add wwan0 0 60 0 0
measure
expect quiet "out only"
lw_uptime_add 60
measure
expect quiet "nothing"

# ICMPv6 never counts: advertisements and neighbour discovery come in and go out as ICMPv6, and are
# in the totals too
lw_uptime_add 60
snmp6-add wwan0 60 60 60 60
measure
expect quiet "ICMPv6 only"
lw_uptime_add 60
snmp6-add wwan0 64 64 60 60
measure
expect traffic "4 packets of data next to 60 of ICMPv6"
lw_uptime_add 60
snmp6-add wwan0 63 64 60 60
measure
expect quiet "3 packets of data next to 60 of ICMPv6"

# a counter that went back (the device was reset), a counter that is missing, one that is not a number
lw_uptime_add 60
snmp6-add wwan0 -100 -100 0 0
measure
expect unknown "a counter that went back"
lw_uptime_add 60
snmp6-add wwan0 60 60 0 0
measure
expect traffic "the baseline after the reset is good again"
for bad in 'Ip6InReceives' 'Ip6OutTransmits' 'Icmp6InMsgs' 'Icmp6OutMsgs'; do
    lw_uptime_add 60
    grep -v "^$bad" "$SNMP/wwan0" >"$SNMP/wwan0.n"
    mv "$SNMP/wwan0.n" "$SNMP/wwan0"
    measure
    expect unknown "no $bad"
    snmp6-add wwan0 0 0 0 0
    # the counter is back, at its old value
    printf '%-32s\t%s\n' "$bad" 1000 >>"$SNMP/wwan0"
    lw_uptime_add 60
    measure
    expect unknown "no baseline was kept from the sample without $bad"
done
lw_uptime_add 60
sed -i 's/^Ip6InReceives.*/Ip6InReceives\t12x/' "$SNMP/wwan0"
measure
expect unknown "a counter that is not a number"

# a baseline older than the age limit is none (two periods and the bound of a check, here 150 s)
fresh
snmp6-add wwan0 0 0 0 0
measure
lw_uptime_add $((MAXAGE + 1))
snmp6-add wwan0 60 60 0 0
measure
expect unknown "a baseline older than the limit"
lw_uptime_add "$MAXAGE"
snmp6-add wwan0 60 60 0 0
measure
expect traffic "a baseline exactly at the limit"

# another device is no baseline
fresh
snmp6-add wwan0 0 0 0 0
snmp6-add wwan1 0 0 0 0
measure wwan0
lw_uptime_add 60
snmp6-add wwan1 60 60 0 0
measure wwan1
expect unknown "a sample of another device"

# another session is no baseline: another call, or the same call started again (its birth moved)
fresh
snmp6-add wwan0 0 0 0 0
measure
lw_uptime_add 60
snmp6-add wwan0 60 60 0 0
sed -i 's/"cid_6":"18"/"cid_6":"19"/' "$T/ifstatus/wwan.json"
measure
expect unknown "another IPv6 call id"
lw_uptime_add 60
snmp6-add wwan0 60 60 0 0
measure
expect traffic "the same session again"
lw_uptime_add 60
snmp6-add wwan0 60 60 0 0
session 1100
measure
expect unknown "the session started again (birth moved by 600 s)"

# the birth is read with the clock jitter of a check: a few seconds do not make a new session
fresh
snmp6-add wwan0 0 0 0 0
measure
lw_uptime_add 60
snmp6-add wwan0 60 60 0 0
session 697
measure
expect traffic "the same session, birth read 3 s later"

# the session is named by the IPv4 call when there is one (dual stack), else by the IPv6 call
fresh
lw_session dual
snmp6-add wwan0 0 0 0 0
measure
lw_uptime_add 60
snmp6-add wwan0 60 60 0 0
measure
expect traffic "dual stack"
lw_expect_eq "$(printf '%s\n' "$LW_T_BASE" | cut -d' ' -f2)" "17/3203210528" "the session key of dual stack"
sed -i 's/"cid_4":"17"/"cid_4":"27"/' "$T/ifstatus/wwan.json"
lw_uptime_add 60
snmp6-add wwan0 60 60 0 0
measure
expect unknown "another IPv4 call in dual stack"

# a session whose call data are incomplete has no key
fresh
snmp6-add wwan0 0 0 0 0
measure
lw_uptime_add 60
snmp6-add wwan0 60 60 0 0
printf '{"up":true,"l3_device":"wwan0"}\n' >"$T/ifstatus/wwan.json"
measure
expect unknown "no call data"

# A wildcard in a saved sample cannot obtain a counter from a matching filename.
fresh
snmp6-add wwan0 0 0 0 0
measure
lw_uptime_add 60
snmp6-add wwan0 60 60 0 0
counter=${LW_T_BASE##* }
LW_T_BASE="${LW_T_BASE% *} [0-9]*"
mkdir "$T/glob"
(
    cd "$T/glob"
    : >"./$counter"
    measure
    expect unknown "a glob in place of a saved counter"
)
echo ok
