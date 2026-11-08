# R13d: a marked table APN follows a new SIM of another operator; an APN changed in LuCI after
# the marker is left alone; a marked APN with an unknown new operator falls back to empty.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/modem/helpers.inc
. /fw/tests/modem/helpers.inc
modem_setup ''
uci batch <<'UCI'
set network.wwan.apn=tmcg-4g
set network.wwan.auth=pap
set network.wwan.username=38267
set network.wwan.password=38267
commit network
set lonewrt.apn=apn
set lonewrt.apn.from_table=tmcg-4g
commit lonewrt
UCI
echo 260030000000001 >"$T/modem/imsi"

apn_event ifup-failed
apn_event ifup-failed
lw_expect_eq "$(uci get network.wwan.apn)" internet "APN for the new card"
lw_expect_eq "$(uci get network.wwan.auth)" pap "auth"
lw_expect_eq "$(uci get network.wwan.username)" internet "username"
lw_expect_eq "$(uci get lonewrt.apn.from_table)" internet "marker"
lw_expect_grep "$T/syslog" "Orange PL (26003): set APN 'internet'"

# Play needs no login: the old one goes
apn_event ifup
echo 260060000000001 >"$T/modem/imsi"
apn_event ifup-failed
apn_event ifup-failed
lw_expect_eq "$(uci get network.wwan.apn)" internet "APN for Play"
lw_expect_eq "$(uci get network.wwan.auth)" none "auth for Play"
lw_expect_eq "$(uci -q get network.wwan.username || :)" "" "username for Play"
lw_expect_eq "$(uci -q get network.wwan.password || :)" "" "password for Play"

# changed in LuCI after the marker: manual from now on
apn_event ifup
uci set network.wwan.apn=custom
uci commit network
echo 297020000000123 >"$T/modem/imsi"
calls=$(count "$T/at-calls" AT+)
apn_event ifup-failed
apn_event ifup-failed
apn_event ifup-failed
lw_expect_eq "$(uci get network.wwan.apn)" custom "APN changed in LuCI"
lw_expect_eq "$(count "$T/at-calls" AT+)" "$calls" "AT commands for an APN changed in LuCI"

# marked APN, unknown new operator: back to the empty APN, marker cleared
apn_event ifup
uci set network.wwan.apn=internet
uci commit network
echo 219010000000001 >"$T/modem/imsi"
events=$(grep -c '^ifup wwan' "$T/events")
apn_event ifup-failed
apn_event ifup-failed
lw_expect_eq "$(uci -q get network.wwan.apn || :)" "" "APN for an unknown operator"
lw_expect_eq "$(uci -q get lonewrt.apn.from_table || :)" "" "marker for an unknown operator"
lw_expect_eq "$(grep -c '^ifup wwan' "$T/events")" $((events + 1)) "reconnects"
lw_expect_grep "$T/syslog" "unknown operator MCCMNC 21901, table APN 'internet' removed"
echo ok
