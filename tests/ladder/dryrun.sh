# DRYRUN=1 (R21b): no reboot, no state or snapshot write, no EDGE switch, no files in /tmp, and
# every syslog entry of both scripts carries [DRY-RUN].
# shellcheck source=tests/ladder/ladder.inc
. /fw/tests/ladder/ladder.inc

lw_net down down
lw_dns down down
echo "previous snapshot" >"$SNAP"

# fingerprint: inode and checksum of state and snapshot, to see a rewrite or a replacement.
fingerprint() { for f in "$STATE" "$SNAP"; do ls -i "$f"; md5sum <"$f"; done; }

tmp_list() { find /tmp -mindepth 1 ! -name lw-at.lock | sort; }

state_set cycles=5 reboots=0 class=hang passive=0 uptime=4000
tmp_before=$(tmp_list)
before=$(fingerprint)
DRYRUN=1 "$WR" >"$T/dry.out" 2>&1 || lw_fail "dry run failed"
lw_expect_eq "$(fingerprint)" "$before" "files after a dry reboot cycle"
lw_expect_grep "$T/dry.out" "REBOOT 1 of 6"
lw_expect_grep "$T/dry.out" "=== reboot 1 cycle=6"

state_set cycles=7 reboots=1 class=hang passive=0 uptime=4000
before=$(fingerprint)
DRYRUN=1 "$WR" >"$T/dry.out" 2>&1 || lw_fail "dry run failed"
lw_expect_eq "$(fingerprint)" "$before" "files after a dry EDGE cycle"
lw_expect_grep "$T/syslog" "wwan-recover: \[DRY-RUN\] EDGE enter"
lw_expect_grep "$T/syslog" "lw-fallback: \[DRY-RUN\] would switch to edge"
lw_expect_eq "$(uci get network.wwan.modes)" lte "uci untouched"
lw_expect_eq "$(cat "$T/modem/zsnt")" 6,0,0 "modem untouched"

lw_net up down
DRYRUN=1 "$WR" >"$T/dry.out" 2>&1 || lw_fail "dry run failed"
lw_expect_eq "$(fingerprint)" "$before" "files after a dry end of failure"
lw_expect_grep "$T/syslog" "\[DRY-RUN\] online on LTE, failure over"

[ ! -s "$T/events" ] || lw_fail "events in dry runs: $(cat "$T/events")"
lw_expect_eq "$(tmp_list)" "$tmp_before" "files in /tmp besides the AT lock"
lw_expect_eq "$(grep -c . "$T/syslog")" "$(grep -c '\[DRY-RUN\]' "$T/syslog")" "all entries marked"
check_format
echo ok
