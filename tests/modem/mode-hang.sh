# R12b: a hung modem and a lock held by someone else; every AT command ends in its limit, the run
# ends after 3 attempts and leaves no AT process behind.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/modem/helpers.inc
. /fw/tests/modem/helpers.inc
modem_setup 1,3,8,20,28,32
lw_at_override ALL HANG

export LW_MODEM_AT_LIMIT=2
t0=$(date +%s)
sh /etc/rc.common /etc/init.d/lw-modem-mode start
wait_log "still differs after 3 attempts (AT command timed out)" 20
# 1 s settle + 3 attempts of one 2 s command + 2 retry pauses
[ $(($(date +%s) - t0)) -le 12 ] || lw_fail "hung modem took $(($(date +%s) - t0)) s"
wait_gone 'lw-modem-mode' 5
sleep 1
no_orphans

rm -f "$T/at/ALL"
: >"$T/syslog"
flock /tmp/lw-at.lock sleep 600 &
holder=$!
sh /etc/rc.common /etc/init.d/lw-modem-mode start
wait_log "still differs after 3 attempts (AT command timed out)" 20
lw_expect_eq "$(count "$T/at-calls" 'AT+ZSNT')" 0 "AT commands through a held lock"
kill "$holder"
wait_gone 'lw-modem-mode' 5
no_orphans
echo ok
