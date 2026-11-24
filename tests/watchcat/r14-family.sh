# R14, R14d, R77, R77a, R77c, D173, D185, D195: watchcat's family check pings, for the families the
# session has, the family's two addresses in turn through the session's own device of that family,
# one packet each, and stops for a family at its first answer; the silence timer is fed by any family.
# A device netifd does not name is never pinged without one, and a session that changes between two
# checks is followed at the next.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/watchcat/helpers.inc
. /fw/tests/watchcat/helpers.inc

A4='8.8.8.8 1.1.1.1'
A6='2001:4860:4860::8888 2606:4700:4700::1111'

# a dual-stack session with the IPv4 over the translation (its own device) and the IPv6 on wwan0, and
# every address silent: both families are pinged, four pings a check, all through a named device
wc_setup
lw_session v6clat
wc_clock 1000
wc_run hook 1110
want=""
for a in $A4; do want="$want
ping -4 -I 464-wwan_6_4 -s 56 -c 1 $a"; done
for a in $A6; do want="$want
ping -6 -I wwan0 -s 56 -c 1 $a"; done
lw_expect_eq "$(head -n 4 "$WCP" | sed 's/^[0-9]* //')" "$(printf '%s\n' "$want" | sed 1d)" "the pings of the first check of a dual-stack session"
! grep -qv ' -I [^ ]* ' "$WCP" || lw_fail "R14d: a ping without a device: $(grep -v ' -I ' "$WCP" | head -n 2)"
lw_expect_eq "$(wc_ifups)" "" "restarts before the period"

# the restart comes by the same silence as for IPv4 alone (R14), with the longer check (R14a): the
# check takes 40 s here, so the checks are at 1060 and 1120, the timer counts from the start of a check
# and has run out at the second, and the restart follows its pings
wc_setup
lw_session v6clat
wc_clock 1000
wc_run hook 1400
lw_expect_eq "$(wc_ifups | head -n 1)" 1160 "second of the first restart of a silent dual-stack session"

# IPv6 alone, answering: online, no restart however long, no ping to an IPv4 address (R77a, R77)
wc_setup
lw_session v6
lw_reach 6 wwan0
wc_clock 1000
wc_run hook 2200
lw_expect_eq "$(wc_ifups)" "" "restarts of an IPv6-only session that answers"
lw_expect_eq "$(wc_pings_of 4)" "" "pings to IPv4 addresses without IPv4 service"
lw_expect_eq "$(wc_pings_of 6 | awk '{ print $1 }' | sort -u | wc -l)" "$(wc_pings_of 6 | wc -l)" "one IPv6 ping per check while the first answers"
! grep -qE '8\.8\.8\.8|1\.1\.1\.1' "$WCP" || lw_fail "an IPv4 address was pinged"

# one family answers, the other is silent: online, nothing restarts (D200); the answering IPv4 stops at
# its first address and the silent IPv6 is pinged at both
wc_setup
lw_session v6clat
lw_reach 4 464-wwan_6_4 8.8.8.8
wc_clock 1000
wc_run hook 1600
lw_expect_eq "$(wc_ifups)" "" "restarts while one family answers"
lw_expect_eq "$(wc_pings_of 4 | awk '{ print $NF }' | sort -u)" 8.8.8.8 "the IPv4 addresses pinged while the first answers"
lw_expect_eq "$(wc_pings_of 6 | awk '{ print $NF }' | sort -u | tr '\n' ' ')" "2001:4860:4860::8888 2606:4700:4700::1111 " "the IPv6 addresses pinged while they are silent"

# an answer that comes over another device is none (the tunnel, the LAN): the ping bound to wwan0
# gets nothing, an answer to a ping bound elsewhere is never asked for
wc_setup
lw_session v4
lw_reach 4 wg0
wc_clock 1000
wc_run hook 1250
lw_expect_eq "$(wc_ifups | head -n 1)" 1140 "restart when only the tunnel would answer"
! grep -q ' -I wg0 ' "$WCP" || lw_fail "a ping was bound to the tunnel"

# R14d, R77c: a family of the session whose device netifd does not name is skipped, never pinged
# without a device. The IPv6 call is there, the settings are not.
wc_setup
lw_session v4
printf '{"up":true,"l3_device":"wwan0","data":{"cid_4":"17","pdh_4":"3203210528","cid_6":"18","pdh_6":"3203210530"}}\n' \
    >"$T/ifstatus/wwan.json"
lw_reach 4 wwan0
wc_clock 1000
wc_run hook 1250
lw_expect_eq "$(wc_pings_of 6)" "" "IPv6 pings while no IPv6 device is ready"
lw_expect_eq "$(grep -vc ' -I ' "$WCP" || true)" 0 "pings without a device"
lw_expect_eq "$(wc_ifups)" "" "restarts while IPv4 answers and IPv6 has no device"

# R77c: a translation that goes away between two checks is not pinged at the next
wc_setup
lw_session v6clat
lw_reach 6 wwan0
cat >"$T/on-sleep" <<'EOF'
#!/bin/sh
[ "$(cut -d. -f1 "$LW_UPTIME_FILE")" -lt 1100 ] || rm -f "$LW_TEST/ifstatus/wwan_6_4.json"
EOF
chmod +x "$T/on-sleep"
wc_clock 1000
wc_run hook 1300
lw_expect_eq "$(grep -c ' -I 464-wwan_6_4 ' "$WCP")" 2 "pings through the translation before it went away"
lw_expect_eq "$(grep -c '^1[123][0-9][0-9] ping -4' "$WCP" || true)" 0 "IPv4 pings after the translation is gone"
