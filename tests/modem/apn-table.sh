# R13a, R13b: an empty APN that works is logged; one that fails twice in a row gets the operator
# table's APN, auth and login with the marker, and the connection comes up again at once.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/modem/helpers.inc
. /fw/tests/modem/helpers.inc
modem_setup ''
rm -f /etc/config/lonewrt

apn_event ifup
lw_expect_grep "$T/syslog" "Auto-APN: connected with an empty APN"

apn_event ifup-failed
lw_expect_eq "$(count "$T/at-calls" AT+)" 0 "AT commands after the first failure"
lw_expect_eq "$(uci -q get network.wwan.apn || :)" "" "APN after the first failure"

apn_event ifup-failed
lw_expect_eq "$(uci get network.wwan.apn)" tmcg-4g "APN"
lw_expect_eq "$(uci get network.wwan.auth)" pap "auth"
lw_expect_eq "$(uci get network.wwan.username)" 38267 "username"
lw_expect_eq "$(uci get network.wwan.password)" 38267 "password"
lw_expect_eq "$(uci get lonewrt.apn.from_table)" tmcg-4g "marker"
lw_expect_eq "$(grep -c '^ifup wwan' "$T/events")" 1 "reconnects"
lw_expect_grep "$T/syslog" "Auto-APN: T-Mobile MNE (29702): set APN 'tmcg-4g'"
lw_expect_no_grep "$T/syslog" "38267"
lw_expect_eq "$(grep -cv '^/dev/ttyUSB2 at ' "$T/at-calls" || :)" 0 "AT calls off /dev/ttyUSB2"

# same card, table APN still failing: nothing rewritten, no reconnect loop, one entry only
apn_event ifup-failed
apn_event ifup-failed
lw_expect_eq "$(grep -c '^ifup wwan' "$T/events")" 1 "reconnects with the APN already set"
lw_expect_eq "$(count "$T/syslog" "already set")" 1 "repeated entries"

# a working connection resets the counter: the next single failure does nothing
apn_event ifup
lw_expect_grep "$T/syslog" "connected with APN 'tmcg-4g' from the operator table"
calls=$(count "$T/at-calls" AT+)
apn_event ifup-failed
lw_expect_eq "$(count "$T/at-calls" AT+)" "$calls" "AT commands after one failure past ifup"

# unknown operator on an empty APN: stays empty, entry with the MCCMNC
uci delete network.wwan.apn
uci commit network
uci delete lonewrt.apn.from_table
uci commit lonewrt
echo 219010000000001 >"$T/modem/imsi"
apn_event ifup-failed
lw_expect_eq "$(uci -q get network.wwan.apn || :)" "" "APN for an unknown operator"
lw_expect_grep "$T/syslog" "unknown operator MCCMNC 21901, empty APN kept; set APN in LuCI"
lw_expect_eq "$(grep -c '^ifup wwan' "$T/events")" 1 "reconnects for an unknown operator"
echo ok
