# R14, R14b, R77a, D195: on the owner's IPv4-only session, `wwan_soft` with the family check does what
# stock watchcat does: the same two IPv4 addresses, through the session's IPv4 device, with the same
# count, size and wait, one check every 60 s, the restart of `wwan` at the same second for the same
# silence, the timer reset after it, the wait after boot, and no IPv6 address or log line. The package's
# own worker runs beside it as the stock side; an entry without the hook option runs it unchanged.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/watchcat/helpers.inc
. /fw/tests/watchcat/helpers.inc

# run_pair NAME SETUP START HORIZON: the same world for the stock worker and the hook's, the results
# in /tmp/cmp/NAME.<variant>.{pings,ifups,log}
run_pair() {
    mkdir -p /tmp/cmp
    for v in stock hook plain; do
        wc_setup
        $2
        wc_clock "$3"
        wc_run "$v" "$4"
        cp "$WCP" "/tmp/cmp/$1.$v.pings"
        wc_ifups >"/tmp/cmp/$1.$v.ifups"
        wc_lines >"/tmp/cmp/$1.$v.log"
    done
}
# expect_same NAME [nolog]: stock and hook did the same pings, restarts and log lines, in the same
# seconds, and so did an entry without the option. The hook leaves out stock's line for an address
# that did not answer while another one did (the silence timer is not counting then), so the log is
# compared only where the whole check is silent.
expect_same() {
    parts='pings ifups log'
    [ "${2:-}" != nolog ] || parts='pings ifups'
    for part in $parts; do
        cmp -s "/tmp/cmp/$1.stock.$part" "/tmp/cmp/$1.hook.$part" ||
            lw_fail "$1: $part differ between stock and the hook: stock $(head -n 6 "/tmp/cmp/$1.stock.$part" | tr '\n' '|') hook $(head -n 6 "/tmp/cmp/$1.hook.$part" | tr '\n' '|')"
        cmp -s "/tmp/cmp/$1.stock.$part" "/tmp/cmp/$1.plain.$part" ||
            lw_fail "$1: $part differ between stock and an entry without the option"
    done
}

# a dead link from the start of the run: pings fail, 10 s each; restart after 120 s of silence, then
# again after every period (the timer is reset after a restart)
dead() { :; }
run_pair dead dead 1000 1500
[ -s /tmp/cmp/dead.stock.pings ] || lw_fail "the stock worker pinged nothing"
[ "$(wc -l </tmp/cmp/dead.stock.ifups)" -ge 3 ] || lw_fail "the stock worker restarted wwan fewer than 3 times in 500 s"
expect_same dead
# the argv of every ping: the family flag, the session's IPv4 device, the size and a single packet
awk '{ $1 = ""; print }' /tmp/cmp/dead.hook.pings | sort -u >/tmp/cmp/argv
lw_expect_eq "$(cat /tmp/cmp/argv)" " ping -4 -I wwan0 -s 56 -c 1 1.1.1.1
 ping -4 -I wwan0 -s 56 -c 1 8.8.8.8" "the pings of the hook on an IPv4-only session"
# R77a: no IPv6 address, no log line that names IPv6, at the default level
! grep -qE ':|-6|IPv6|ipv6' /tmp/cmp/dead.hook.pings || lw_fail "R77a: an IPv6 ping on an IPv4-only session"
! grep -qiE 'ipv6|2001:|2606:' /tmp/cmp/dead.hook.log || lw_fail "R77a: a log line names IPv6"

# the wait after boot is stock: the worker waits until uptime = period before it counts
run_pair boot dead 50 600
expect_same boot

# the link comes back before the period is up: no restart, in both
back() { echo 'sleep 0' >/dev/null; }
cat >/tmp/cmp/on-back <<'EOS'
#!/bin/sh
[ "$(cut -d. -f1 "$LW_UPTIME_FILE")" -lt 1080 ] || echo '4 wwan0 *' >"$LW_TEST/net/paths"
EOS
chmod +x /tmp/cmp/on-back
for v in stock hook plain; do
    wc_setup
    cp /tmp/cmp/on-back "$T/on-sleep"
    wc_clock 1000
    wc_run "$v" 1400
    lw_expect_eq "$(wc_ifups)" "" "restarts of $v when the link returns at 1080 s"
done

# one of the two addresses answers: the same pings as stock, no restart (the first fails, the second
# answers, so nothing is left unpinged)
one() { lw_reach 4 wwan0 1.1.1.1; }
run_pair one one 1000 1300
expect_same one nolog
lw_expect_eq "$(cat /tmp/cmp/one.hook.ifups)" "" "restarts with one address answering"

# both answer: no restart; the hook stops at the first answer where stock pings both, so its pings
# are the first address of each check
both() { lw_reach 4 wwan0; }
run_pair both both 1000 1300
lw_expect_eq "$(cat /tmp/cmp/both.hook.ifups)" "" "restarts with both addresses answering"
lw_expect_eq "$(cat /tmp/cmp/both.stock.ifups)" "" "stock restarts with both addresses answering"
lw_expect_eq "$(awk '{ print $NF }' /tmp/cmp/both.hook.pings | sort -u)" "8.8.8.8" "the addresses the hook pinged while the first answers"
lw_expect_eq "$(wc -l </tmp/cmp/both.hook.pings)" "$(grep -c ' 8.8.8.8$' /tmp/cmp/both.stock.pings)" "checks of the hook and of stock"
# the checks keep the 60 s step in both
lw_expect_eq "$(awk '{ print $1 }' /tmp/cmp/both.hook.pings | tr '\n' ' ')" \
    "$(grep ' 8.8.8.8$' /tmp/cmp/both.stock.pings | awk '{ print $1 }' | tr '\n' ' ')" "the seconds of the checks"

# R14d, D195: every netifd lookup of the hook fails (netifd busy or restarting) while stock resolved
# its device: the IPv4-only session is still pinged on its device, so a failed lookup is no silence
# that stock would not have, and the restarts come at the same seconds
mkdir -p /tmp/cmp/nonetifd
printf '#!/bin/sh\necho "Interface not found"\nexit 1\n' >/tmp/cmp/nonetifd/ifstatus
chmod +x /tmp/cmp/nonetifd/ifstatus
for w in dead one; do
    for v in stock hook; do
        wc_setup
        $w
        [ "$v" = stock ] || PATH=/tmp/cmp/nonetifd:$PATH
        wc_clock 1000
        wc_run "$v" 1300
        PATH=${PATH#/tmp/cmp/nonetifd:}
        cp "$WCP" "/tmp/cmp/nonetifd-$w.$v.pings"
        wc_ifups >"/tmp/cmp/nonetifd-$w.$v.ifups"
    done
    for part in pings ifups; do
        cmp -s "/tmp/cmp/nonetifd-$w.stock.$part" "/tmp/cmp/nonetifd-$w.hook.$part" ||
            lw_fail "R14d: $w, lookups failing: $part differ between stock and the hook"
    done
done
