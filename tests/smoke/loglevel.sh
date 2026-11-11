# R29c: lw_debug of common.sh writes one daemon.debug line with the given tag, only when
# lonewrt.log.level is debug; any other value, an absent option or a missing section is info. The
# level is read once per process.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
lw_setup
# shellcheck source=src/files/usr/lib/lw/common.sh
. /usr/lib/lw/common.sh
P=$T/syslog.prio

# no section at all: info
lw_debug tagx "invisible 1"
lw_expect_eq "$(cat "$P" 2>/dev/null)" "" "debug line without a log section"

# a fresh shell per level: the level is read at the first call and kept
for level in info Debug DEBUG '' other; do
    : >"$P"
    uci set lonewrt.log=log
    uci set lonewrt.log.level="$level"
    uci commit lonewrt
    sh -c '. /usr/lib/lw/common.sh; lw_debug tagx "invisible 2"'
    lw_expect_eq "$(cat "$P")" "" "debug line at level '$level'"
done

uci set lonewrt.log.level=debug
uci commit lonewrt
: >"$P"
sh -c '. /usr/lib/lw/common.sh; lw_debug tagx "visible one"; lw_debug tagy "visible two"'
lw_expect_eq "$(cat "$P")" "daemon.debug tagx: visible one
daemon.debug tagy: visible two" "debug lines at the debug level"
lw_expect_eq "$(sed -n 1p "$T/syslog" | cut -d' ' -f2-)" "tagx: visible one" "syslog line"

# the notice logger is unchanged and is not affected by the level
: >"$P"
uci set lonewrt.log.level=info
uci commit lonewrt
sh -c '. /usr/lib/lw/common.sh; lw_log tagz "plain"'
lw_expect_eq "$(cat "$P")" "daemon.notice tagz: plain" "lw_log at the info level"

# read once: a change of the level after the first call does not show in that process
: >"$P"
uci set lonewrt.log.level=debug
uci commit lonewrt
sh -c '. /usr/lib/lw/common.sh; lw_debug t "first"; uci set lonewrt.log.level=info; uci commit lonewrt; lw_debug t "second"'
lw_expect_eq "$(cat "$P")" "daemon.debug t: first
daemon.debug t: second" "debug lines after a change of the level in the same process"

# DRYRUN=1 marks the line as lw_log does
: >"$P"
uci set lonewrt.log.level=debug
uci commit lonewrt
sh -c '. /usr/lib/lw/common.sh; DRYRUN=1 lw_debug t "dry"'
lw_expect_eq "$(cat "$P")" "daemon.debug t: [DRY-RUN] dry" "debug line in a dry run"
echo ok
