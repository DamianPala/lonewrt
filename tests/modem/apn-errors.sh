# R13c: SIM not READY, IMSI unreadable in 6 reads, a hung port and a spent budget all leave the
# settings alone with an Auto-APN entry; a timed-out command is not repeated and the run stays in
# its budget. R13d: the hotplug returns at once and only one worker runs.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/modem/helpers.inc
. /fw/tests/modem/helpers.inc
modem_setup ''

echo 'SIM PIN' >"$T/modem/cpin"
apn_event ifup-failed
apn_event ifup-failed
lw_expect_grep "$T/syslog" "Auto-APN: SIM not ready (AT+CPIN?: 'SIM PIN'), APN unchanged"
lw_expect_eq "$(count "$T/at-calls" AT+CIMI)" 0 "IMSI reads with a locked SIM"

echo READY >"$T/modem/cpin"
lw_at_override AT+CIMI SILENT
t0=$(date +%s)
apn_event ifup-failed
lw_expect_eq "$(count "$T/at-calls" AT+CIMI)" 6 "IMSI reads"
lw_expect_grep "$T/syslog" "Auto-APN: no IMSI after 6 reads, APN unchanged"
[ $(($(date +%s) - t0)) -le 150 ] || lw_fail "worker over 150 s"

lw_at_override AT+CIMI HANG
export LW_APN_AT_LIMIT=3
apn_event ifup-failed
lw_expect_eq "$(count "$T/at-calls" AT+CIMI)" 7 "a timed-out IMSI read is not repeated"
lw_expect_grep "$T/syslog" "Auto-APN: AT+CIMI timed out"

# budget: a hung read gets only what is left of it (budget less the 20 s tail = 6 s), and timeout
# is the last resort
export LW_APN_AT_LIMIT=20 LW_APN_BUDGET=26
t0=$(date +%s)
apn_event ifup-failed
[ $(($(date +%s) - t0)) -le 8 ] || lw_fail "worker ran $(($(date +%s) - t0)) s with a 6 s budget"
sleep 1
no_orphans
export LW_APN_BUDGET=150 LW_APN_AT_LIMIT=4

lw_expect_eq "$(uci -q get network.wwan.apn || :)" "" "APN after errors"
lw_expect_no_grep "$T/events" "ifup"

# one worker at a time; the hotplug returns at once even with the modem hung
lw_at_override 'AT+CPIN?' HANG
: >"$T/at-calls"
fails=$(cat /tmp/lw-apn.fails)
hotplug ifup-failed
hotplug ifup-failed
hotplug ifup-failed
sleep 1
lw_expect_eq "$(cat /tmp/lw-apn.fails)" $((fails + 3)) "failures counted"
wait_gone 'usr/lib/lw/lw-apn' 15
lw_expect_eq "$(count "$T/at-calls" 'AT+CPIN?')" 1 "CPIN reads by parallel events"
no_orphans
echo ok
