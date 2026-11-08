# R34b: a busy AT lock skips the inbox pass at once. R12b, R38: a hung modem and a network that
# never answers end within their limits and leave no process; a message waiting for such a
# network stays queued. Damaged state files do not stop the service.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup ''
passes 2

# busy lock: no wait, no AT command, and the bot still answers
flock /tmp/lw-at.lock sleep 4 &
holder=$!
sleep 1
sms_in 0 +38200000001 '11/07/26 10:00:00' 'behind a busy lock'
tg_push "$TG_CHAT" /help
: >"$T/at-calls"
t0=$(date +%s)
passes 3
[ "$(elapsed_since "$t0")" -le 2 ] || lw_fail "passes waited for the busy lock"
lw_expect_eq "$(cat "$T/at-calls")" "" "AT commands through a busy lock"
expect_sent 1
wait "$holder"
passes 2
expect_sent 2
expect_last 'behind a busy lock'

# hung modem: each pass ends within the 2 s AT limit
lw_at_override ALL HANG
sms_in 1 +38200000001 '11/07/26 10:01:00' 'modem hangs'
t0=$(date +%s)
passes 3
took=$(elapsed_since "$t0")
[ "$took" -le 8 ] || lw_fail "3 passes with a hung modem took $took s"
rm -f "$T/at/ALL"
sleep 1
no_orphans
passes 2
expect_sent 3

# network that never answers: the queued message waits, the pass ends within its limits
echo hang >"$G/net"
sms_in 2 +38200000001 '11/07/26 10:02:00' 'network hangs'
passes 2
t0=$(date +%s)
pass
# one sendMessage and one getUpdates, each 2 s + 2 s at most
took=$(elapsed_since "$t0")
[ "$took" -le 9 ] || lw_fail "a pass with a hung network took $took s"
lw_expect_eq "$(find /etc/lw-notify/queue -type f | wc -l)" 1 "queued while the network hangs"
sleep 1
no_orphans
echo up >"$G/net"
pass
expect_sent 4
expect_last 'network hangs'

# damaged state files: the next pass still polls and forwards
for f in offset next_inbox passes count balance_req fail_since; do
    echo 'garbage x' >"/tmp/lw-notify/$f"
done
echo 'not a key' >>/etc/lw-notify/seen
sms_in 3 +38200000001 '11/07/26 10:03:00' 'after the damage'
passes 3
expect_sent 5
expect_last 'after the damage'

# a failing list read is retried once, then waits for the next count, not every second (R34b)
echo FAIL >"$T/at/RECV"
sms_in 4 +38200000001 '11/07/26 10:04:00' 'list read fails'
: >"$T/at-calls"
LW_NOTIFY_CLOCK=/proc/uptime LW_NOTIFY_POLL=5 LW_NOTIFY_LONGPOLL=1 lw-notify run \
    </dev/null >/dev/null 2>&1 &
svc=$!
sleep 9
kill "$svc"
wait "$svc" || :
reads=$(grep -c recv "$T/at-calls" || :)
[ "$reads" -le 5 ] || lw_fail "$reads list reads in 9 s with a failing modem"
echo ok
