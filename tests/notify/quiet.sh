# R34c: ordinary passes write nothing to flash and nothing to syslog; a new SMS and a sent message
# do write. R34d: the bot token appears in no log, no file outside the config and no reply, also
# when Telegram rejects it or the network fails.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup 7.50
sms_in 0 +38200000001 '11/07/26 10:00:00' 'already there'
passes 3

# flash_state: every file under /etc and /root with its inode (a rename-rewrite changes it), size
# and content hash (busybox has no stat)
flash_state() {
    find /etc /root -type f -exec ls -li {} + | sort
    find /etc /root -type f -exec md5sum {} + | sort
}
before=$(flash_state)
case $before in *lw-notify/seen*) ;; *) lw_fail "flash state misses the seen list: $before" ;; esac
sleep 1
tg_push "$TG_CHAT" 'just chatting'
tg_push "$TG_OTHER" /status
passes 25
lw_expect_eq "$(flash_state)" "$before" "flash after idle passes"
lw_expect_eq "$(cat "$T/syslog")" "" "syslog after idle passes"
lw_expect_grep "$T/at-calls" recv

sms_in 1 +38200000002 '11/07/26 10:01:00' 'new one'
passes 2
expect_sent 1
[ "$(flash_state)" != "$before" ] || lw_fail "a new SMS wrote nothing to flash"

# token: wrong-token answers, network errors, a /status and a /sms reply
tg_push "$TG_CHAT" /status
tg_push "$TG_CHAT" /sms
tg_push "$TG_CHAT" /help
pass
echo down >"$G/net"
sms_in 2 +38200000003 '11/07/26 10:02:00' 'while down'
passes 3
echo hang >"$G/net"
pass
echo up >"$G/net"
echo 'other:token' >"$G/token"
passes 3
echo "$TG_TOKEN" >"$G/token"
passes 2
lw-notify balance
echo '2026-11-07_10:00:03 zsnt=6 loss=0%' >/tmp/lw-signal.log
lw_expect_grep "$T/syslog" "Telegram unreachable"
for f in "$T/syslog" /tmp/lw-signal.log "$G"/sent/*.text; do
    lw_expect_no_grep "$f" "$TG_TOKEN"
    lw_expect_no_grep "$f" TESTtokq7x9
done
hits=$(grep -rlF TESTtokq7x9 /etc /root /tmp 2>/dev/null | grep -v '^/etc/config/lonewrt$' || :)
[ -z "$hits" ] || lw_fail "token in $hits"
sleep 1
no_orphans
echo ok
