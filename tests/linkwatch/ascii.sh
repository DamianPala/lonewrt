# R29b: the debug lines that quote what uqmi answered carry printable ASCII only, one line each,
# at most 300 bytes: the modem can send any byte (an operator name, say). Two quoting paths: an
# unusable data status, and settings that are not "Out of call" while the data status says
# disconnected.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc

lk_debug_on() {
    uci set lonewrt.log=log
    uci set lonewrt.log.level=debug
    uci commit lonewrt
}

# a UTF-8 letter and a control byte inside the answer (the stand-in takes one line per answer)
odd='"ab\303\251cd\001ef"'

lk_setup
lk_debug_on
printf "$odd\n" >"$T/uqmi/q-data"
lk_lost
lw-linkwatch once
want="data status: no usable answer '\"ab??cd?ef\"', no action"
lk_debug_lines | grep -qF "lw-linkwatch: $want" || lw_fail "no filtered line '$want' in: $(lk_debug_lines)"

lk_setup
lk_debug_on
printf "$odd\n" >"$T/uqmi/q-settings"
lk_lost
lw-linkwatch once
want="data status disconnected but settings answer '\"ab??cd?ef\"', no action"
lk_debug_lines | grep -qF "lw-linkwatch: $want" || lw_fail "no filtered line '$want' in: $(lk_debug_lines)"

# whatever the watcher logged in these runs is printable ASCII
! LC_ALL=C grep -q '[^ -~]' "$T/syslog.prio" || lw_fail "a non-ASCII byte reached the log"
echo ok
