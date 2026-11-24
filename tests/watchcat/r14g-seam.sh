# R14g, D204: after each scheduled family check of wwan_soft in a session with IPv6, watchcat's hook
# writes /var/run/lw-family/ipv6 through one function of probe.sh: one line `<cid_4>/<pdh_4> <birth>
# <second> <result>`, in a directory of mode 0700, replaced at once. No other check writes it; a
# session without IPv6 (or without an IPv4 call) writes nothing and removes nothing.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/watchcat/helpers.inc
. /fw/tests/watchcat/helpers.inc

F=/var/run/lw-family/ipv6
mode_of() { ls -ld "$1" | cut -c1-10; }

# a dual-stack session that came up at second 760 (netifd's uptime 300 at the check of 1060), IPv4
# answering, IPv6 silent: the first check at 1060 starts its IPv6 pings at that second
wc_setup
lw_session dual
wc_uptime 300
lw_reach 4 wwan0
wc_clock 1000
wc_run hook 1070
lw_expect_eq "$(cat $F)" "17/3203210528 760 1060 none" "the line of a silent IPv6"
lw_expect_eq "$(mode_of /var/run/lw-family)" drwx------ "mode of the directory"
lw_expect_eq "$(ls -A /var/run/lw-family | grep -v '^ipv6$' || true)" "" "files beside the result (a temp file left behind)"
lw_expect_eq "$(wc -l <$F)" 1 "lines in the file"

# the next check replaces it (same session, a later second), also with a directory of another mode
chmod 0755 /var/run/lw-family
wc_run hook 1200
lw_expect_eq "$(cat $F)" "17/3203210528 880 1180 none" "the line after the next check (the stand-in uptime is fixed at 300, so the birth moves with the read)"
lw_expect_eq "$(mode_of /var/run/lw-family)" drwx------ "mode of a directory that had another"

# IPv6 answers: answer
wc_setup
lw_session dual
wc_uptime 300
lw_reach 4 wwan0
lw_reach 6 wwan0
wc_clock 1000
wc_run hook 1070
lw_expect_eq "$(cat $F)" "17/3203210528 760 1060 answer" "the line of an answering IPv6"

# the IPv6 call has no device yet: nodev, and nothing was pinged for IPv6
wc_setup
lw_session v4
printf '{"up":true,"uptime":300,"l3_device":"wwan0","data":{"cid_4":"17","pdh_4":"3203210528","cid_6":"18","pdh_6":"3203210530"}}\n' \
    >"$T/ifstatus/wwan.json"
lw_reach 4 wwan0
wc_clock 1000
wc_run hook 1070
lw_expect_eq "$(cat $F)" "17/3203210528 760 1060 nodev" "the line of an IPv6 without a device"
lw_expect_eq "$(wc_pings_of 6)" "" "IPv6 pings without a device"

# netifd without an uptime: the birth is -
wc_setup
lw_session dual
lw_reach 4 wwan0
wc_clock 1000
wc_run hook 1070
lw_expect_eq "$(cat $F)" "17/3203210528 - 1060 none" "the line without netifd's uptime"

# a session without IPv6: nothing written, and the file there stays as it was
wc_setup
lw_session v4
mkdir -p /var/run/lw-family
echo 'old line' >$F
wc_clock 1000
wc_run hook 1200
lw_expect_eq "$(cat $F)" "old line" "the file of an IPv4-only session"
rm -f $F
wc_run hook 1300
[ ! -e $F ] || lw_fail "an IPv4-only session wrote the result"

# a session without an IPv4 call (IPv6 alone): nothing written, the file stays
wc_setup
lw_session v6
lw_reach 6 wwan0
mkdir -p /var/run/lw-family
echo 'old line' >$F
wc_clock 1000
wc_run hook 1200
lw_expect_eq "$(cat $F)" "old line" "the file of an IPv6-only session"

# R14g: the writer makes no directory of its own where the family directory is a link or a file, and
# writes nothing through it
wc_setup
lw_session dual
wc_uptime 300
lw_reach 4 wwan0
mkdir -p /tmp/elsewhere
ln -s /tmp/elsewhere /var/run/lw-family
wc_clock 1000
wc_run hook 1200
lw_expect_eq "$(ls -A /tmp/elsewhere)" "" "files written through a link in place of the family directory"
lw_expect_eq "$(ls -ld /var/run/lw-family | cut -c1)" l "the link in place of the family directory after the checks"
wc_setup
lw_session dual
wc_uptime 300
lw_reach 4 wwan0
: >/var/run/lw-family
wc_clock 1000
wc_run hook 1200
[ -f /var/run/lw-family ] && [ ! -s /var/run/lw-family ] || lw_fail "the file in place of the family directory was changed"

# no other check writes it: the rounds of wwan-recover and lw-notify leave it alone, and the writer
# has one caller, the hook of watchcat
wc_setup
lw_session dual
lw_reach 4 wwan0
# shellcheck source=src/files/usr/lib/lw/common.sh
. /usr/lib/lw/common.sh
# shellcheck source=src/files/usr/lib/lw/probe.sh
. /usr/lib/lw/probe.sh
rm -rf /var/run/lw-family
lw_probe_round recover || :
lw_probe_round notify || :
lw_probe_round || :
[ ! -e /var/run/lw-family ] || lw_fail "R14g: a round of another consumer wrote in /var/run/lw-family"
lw_expect_eq "$(grep -rl 'lw_probe_publish_v6' /fw/src | sed 's|^/fw/src/files/||' | sort | tr '\n' ' ')" \
    "usr/lib/lw/probe.sh usr/lib/lw/watchcat-family.sh " "files that mention the writer"
lw_expect_eq "$(grep -c 'lw_probe_publish_v6' /fw/src/files/usr/lib/lw/watchcat-family.sh)" 1 "calls of the writer in the hook"
