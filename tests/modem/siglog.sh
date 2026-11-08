# R28: one line with the fields in the order and format of the SPEC example. R28b: a line also
# without modem and internet, and a run with a held lock ends in its limits. R28a: 5000 lines.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/modem/helpers.inc
. /fw/tests/modem/helpers.inc
modem_setup ''
L=/tmp/lw-signal.log
cat >"$T/modemdata.json" <<'EOF'
[{"device":"ZTE MF289F"},{"registration":"1"},{"mode":"LTE-A B3 (1800 MHz) / B1 (2100 MHz)","addon":[
{"key":"Primary band","value":"B3 (1800 MHz) @20 MHz"},{"key":"(S1) band","value":"B1 (2100 MHz) @10 MHz"},
{"key":"RSRP","value":"-85 dBm"},{"key":"RSRQ","value":"-14 dB"},{"key":"SINR","value":"5.4 dB"},
{"key":"RSSI","value":"-53 dBm"},{"key":"PCI","value":"157"}]}]
EOF
lw_net up down
echo up >"$T/wg"

lw-siglog
line=$(tail -n 1 "$L")
rest=${line#* }
lw_expect_eq "$rest" "zsnt=6 net=LTE-A_B3_(1800_MHz)_/_B1_(2100_MHz) pb=B3(1800MHz) s1=B1(2100MHz) rsrp=-85dBm rsrq=-14dB sinr=5.4dB rssi=-53dBm pci=157 loss=0% rtt=36.459 wg_age=0s" "signal line"
case ${line%% *} in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;;
    *) lw_fail "time stamp '${line%% *}'" ;;
esac
grep -n '/dev/ttyUSB1' "$T/at-calls" && lw_fail "AT on the LuCI port"

# no modem answer, no internet, no tunnel
rm -f "$T/modemdata.json" "$T/wg"
lw_at_override ALL SILENT
lw_net down down
lw-siglog
lw_expect_eq "$(wc -l <"$L")" 2 "lines"
rest=$(tail -n 1 "$L" | cut -d' ' -f2-)
lw_expect_eq "$rest" "zsnt=? net=? pb=? s1=? rsrp=? rsrq=? sinr=? rssi=? pci=? loss=100% rtt=? wg_age=?" "line without modem"

# hung modem behind a held lock: the run ends in its limits and still writes the line
rm -f "$T/at/ALL"
flock /tmp/lw-at.lock sleep 600 &
t0=$(date +%s)
LW_SIGLOG_LIMIT=2 LW_SIGLOG_AT_LIMIT=2 lw-siglog
[ $(($(date +%s) - t0)) -le 6 ] || lw_fail "run with a held lock took $(($(date +%s) - t0)) s"
lw_expect_eq "$(wc -l <"$L")" 3 "lines"
tail -n 1 "$L" | grep -q ' zsnt=? net=? ' || lw_fail "line with a held lock: $(tail -n 1 "$L")"
kill %1 2>/dev/null || :

# R28a: never more than 5000 lines, the newest at the end
seq 1 5000 | sed 's/^/old /' >"$L"
LW_SIGLOG_LIMIT=1 LW_SIGLOG_AT_LIMIT=1 lw-siglog
lw_expect_eq "$(wc -l <"$L")" 5000 "lines after trimming"
lw_expect_eq "$(head -n 1 "$L")" "old 2" "first line after trimming"
tail -n 1 "$L" | grep -q ' zsnt=' || lw_fail "newest line missing"
echo ok
