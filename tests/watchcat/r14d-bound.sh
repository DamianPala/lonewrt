# R14d, R77c: a family check of watchcat ends within 40 s with its device lookups included, on the real
# clock. Pings that hang are cut to the time left of the round's bound (and to 10 s, the wait of a
# busybox ping without -W); netifd lookups that stall (each is cut at 2 s) take their share of it.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/watchcat/helpers.inc
. /fw/tests/watchcat/helpers.inc

wc_setup
lw_session v6clat
export LW_UPTIME_FILE=/proc/uptime
# shellcheck source=src/files/usr/lib/lw/common.sh
. /usr/lib/lw/common.sh
# shellcheck source=src/files/usr/lib/lw/probe.sh
. /usr/lib/lw/probe.sh
touch "$T/ping-hang"

# four addresses, every ping hangs, the lookups are quick: the bound of the round (37 s) cuts the
# last ping short, the check ends before 40 s and has pinged all four addresses
t0=$(date +%s)
lw_probe_round watchcat || :
dt=$(($(date +%s) - t0))
[ "$dt" -le 40 ] || lw_fail "R14d: a check of four hanging pings took $dt s"
[ "$dt" -ge 30 ] || lw_fail "R14d: a check of four hanging pings took only $dt s, pings were cut short"
lw_expect_eq "$(wc -l <"$WCP")" 4 "pings of the check"
lw_expect_eq "$LW_P_ONLINE" 0 "online with every ping hanging"

# the lookups stall too (4 of them, 2 s each): the pings get what is left of a short bound, and the
# check still ends within it, with the grace of the kill
: >"$WCP"
touch "$T/ifstatus/hang"
LW_P_WBOUND=12
t0=$(date +%s)
lw_probe_round watchcat || :
dt=$(($(date +%s) - t0))
[ "$dt" -le 14 ] || lw_fail "R14d: a check with stalled lookups and a bound of 12 s took $dt s"
[ "$(wc -l <"$WCP")" -le 2 ] || lw_fail "R14d: more pings than the bound leaves room for: $(wc -l <"$WCP")"
[ ! -s "$WCP" ] || ! grep -qv ' -I ' "$WCP" || lw_fail "R14d: a ping without a device"
