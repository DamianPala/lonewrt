# R29c: at the debug level lw-siglog writes each sample to syslog too (daemon.debug, tag lw-siglog),
# the same line as in /tmp/lw-signal.log; at the info level there is no syslog entry, and the RAM
# log is the same at both levels (R28).
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/modem/helpers.inc
. /fw/tests/modem/helpers.inc
modem_setup ''
L=/tmp/lw-signal.log
lw_net up down
echo up >"$T/wg"
uci set lonewrt.log=log

uci set lonewrt.log.level=info
lw-siglog
lw_expect_eq "$(wc -l <"$L")" 1 "lines in the RAM log at the info level"
lw_expect_eq "$(cat "$T/syslog")" "" "syslog at the info level"

uci set lonewrt.log.level=debug
lw-siglog
lw_expect_eq "$(wc -l <"$L")" 2 "lines in the RAM log at the debug level"
lw_expect_eq "$(wc -l <"$T/syslog" | tr -d ' ')" 1 "syslog lines at the debug level"
lw_expect_eq "$(sed 's/^[0-9]* lw-siglog: //' "$T/syslog")" "$(tail -n 1 "$L")" "the syslog line is the RAM log line"
lw_expect_eq "$(cut -d' ' -f1-2 "$T/syslog.prio")" "daemon.debug lw-siglog:" "priority and tag"
echo ok
