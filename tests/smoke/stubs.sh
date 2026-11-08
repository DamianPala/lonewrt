# Smoke test of the sandbox and stubs: the shared AT helper, the modem model, ping by network.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
lw_setup
# shellcheck source=src/files/usr/lib/lw/common.sh
. /usr/lib/lw/common.sh
lw_expect_eq "$(lw_at 5 'AT+ZSNT?')" "+ZSNT: 6,0,0" "ZSNT read"
lw_at 5 'AT+ZSNT=0,0,0' >/dev/null
lw_expect_eq "$(lw_at 5 'AT+ZSNT?')" "+ZSNT: 0,0,0" "ZSNT after set"
lw_at_override 'AT+CPIN?' HANG
rc=0
lw_at 2 'AT+CPIN?' >/dev/null || rc=$?
lw_expect_eq "$rc" 124 "hung AT returns 124"
lw_net down up
ping -c 1 8.8.8.8 >/dev/null || lw_fail "EDGE should be up in auto mode"
echo 6,0,0 >"$T/modem/zsnt"
! ping -c 1 8.8.8.8 >/dev/null || lw_fail "LTE should be down"
flock /tmp/lw-at.lock sleep 3 &
sleep 1
rc=0
lw_at_nowait 5 'AT+ZSNT?' >/dev/null || rc=$?
lw_expect_eq "$rc" 75 "busy lock returns 75 at once"
lw_uptime_add 300
lw_expect_eq "$(lw_uptime)" 1300 "uptime"
lw_log smoke "hello"
lw_expect_grep "$T/syslog" "smoke: hello"
lw_reboot_sim
[ ! -e /tmp/lw-at.lock ] || lw_fail "reboot sim keeps /tmp"
echo ok
