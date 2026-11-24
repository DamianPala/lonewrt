# R77b, D185, D200: a family of the session that gets no answer in 3 scheduled checks of watchcat in a
# row while the other family answers is a family lost: one syslog line naming it, one more at its
# first answer after that, no restart of wwan for it, and the silence timer is fed by the other
# family. Checks in which no family answers, and a family the session does not have, are no part of it.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/watchcat/helpers.inc
. /fw/tests/watchcat/helpers.inc

lost_lines() { wc_lines | grep -E '^IPv[46] ' || :; }

# IPv6 stops answering while IPv4 does: checks at 1060, 1120, 1180 (IPv6 silent each time)
wc_setup
lw_session dual
lw_reach 4 wwan0
wc_clock 1000
wc_run hook 1175
lw_expect_eq "$(lost_lines)" "" "family lines after 2 silent checks"
wc_setup
lw_session dual
lw_reach 4 wwan0
wc_clock 1000
wc_run hook 1500
lw_expect_eq "$(lost_lines | wc -l)" 1 "family lines after many silent checks: $(lost_lines)"
lost_lines | grep -q '^IPv6 did not answer in 3 checks in a row' || lw_fail "the line does not name IPv6: $(lost_lines)"
lw_expect_eq "$(wc_ifups)" "" "restarts for a lost family (D200)"
# the line comes with the third check (second 1180), not before
lw_expect_eq "$(grep ' watchcat\[' "$T/syslog" | grep 'IPv6 did not answer' | cut -d' ' -f1)" 1200 "second of the line (the third check, at 1180, ends after its pings)"

# and it answers again: one more line, at the first answer
wc_setup
lw_session dual
lw_reach 4 wwan0
cat >"$T/on-sleep" <<'EOS'
#!/bin/sh
[ "$(cut -d. -f1 "$LW_UPTIME_FILE")" -lt 1400 ] || grep -q '^6 ' "$LW_TEST/net/paths" || echo '6 wwan0 *' >>"$LW_TEST/net/paths"
EOS
chmod +x "$T/on-sleep"
wc_clock 1000
wc_run hook 1700
lw_expect_eq "$(lost_lines | sed 's/ in 3 checks.*//' | tr '\n' '|')" "IPv6 did not answer|IPv6 answers again|" "the two lines of a lost and returned IPv6"
lw_expect_eq "$(wc_ifups)" "" "restarts for a lost and returned family"

# the same for IPv4 lost while IPv6 answers
wc_setup
lw_session dual
lw_reach 6 wwan0
wc_clock 1000
wc_run hook 1500
lw_expect_eq "$(lost_lines | sed 's/ in 3 checks.*//')" "IPv4 did not answer" "the line of a lost IPv4"
lw_expect_eq "$(wc_ifups)" "" "restarts for a lost IPv4"

# a short outage is no loss: IPv6 silent for 2 checks, then answering, then silent for 2 again
wc_setup
lw_session dual
lw_reach 4 wwan0
cat >"$T/on-sleep" <<'EOS'
#!/bin/sh
n=$(cut -d. -f1 "$LW_UPTIME_FILE")
sed -i '/^6 /d' "$LW_TEST/net/paths"
if { [ "$n" -ge 1150 ] && [ "$n" -lt 1210 ]; }; then echo '6 wwan0 *' >>"$LW_TEST/net/paths"; fi
EOS
chmod +x "$T/on-sleep"
wc_clock 1000
wc_run hook 1330
lw_expect_eq "$(lost_lines)" "" "family lines when the silence is broken by an answer"

# both families silent: no family is lost, the silence timer runs out and wwan is restarted (R14)
wc_setup
lw_session dual
wc_clock 1000
wc_run hook 1500
lw_expect_eq "$(lost_lines)" "" "family lines when no family answers"
[ -n "$(wc_ifups)" ] || lw_fail "no restart when no family answers"

# an IPv4-only session has no family to lose, answering or not (R77a)
wc_setup
lw_session v4
wc_clock 1000
wc_run hook 1500
lw_expect_eq "$(lost_lines)" "" "family lines of an IPv4-only session"
