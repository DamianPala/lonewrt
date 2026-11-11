# R49c: a handle from start-network that differs from the pdh_4 of netifd is told at the info level,
# in the line of the incident; netifd's data is left alone (D80: no set_data). The same handle adds
# nothing (tests/linkwatch/restore.sh).
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc
lk_setup
lk_lost
echo 99 >"$T/uqmi/handle"
lw-linkwatch once
lw_expect_eq "$(lk_info)" 1 "watcher syslog lines"
lk_lines | grep -qF "restored in place after 1 s, address $OLD_ADDR -> $NEW_ADDR, new data handle 99 (netifd has 3203210528)" ||
    lw_fail "info line: $(lk_lines)"
! grep -rq 'set_data' /fw/src/files || lw_fail "set_data is used"

# uqmi prints the handle as a signed number (the router's was -882662896): a leading minus is a
# handle, not a failed start, so the lease is renewed in the same step and not 2 s later
lk_setup
lk_lost
echo -882662896 >"$T/uqmi/handle"
lw-linkwatch once
lw_expect_eq "$(lk_calls_of --start-network)" 1 "start-network calls with a negative handle"
lk_lines | grep -qF "restored in place after 1 s, address $OLD_ADDR -> $NEW_ADDR, new data handle -882662896" ||
    lw_fail "negative handle: $(lk_lines)"
# a lone minus is no handle
lk_setup
lk_lost
echo - >"$T/uqmi/handle"
LW_LOG_LEVEL=debug lw-linkwatch once
lk_lines | grep -qF "start-network answered '-'" || lw_fail "a lone minus was taken as a handle: $(lk_lines)"
echo ok
