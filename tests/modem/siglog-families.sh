# R28, D185: the signal line on every kind of link. `loss` and `rtt` come from one ping of the session's
# IPv4 service when it has one (native, or through the translation), else of its IPv6; a session with
# both families appends `loss6` and `rtt6` after `wg_age`; the line of an IPv4-only session stays as
# it was and no IPv6 address is pinged for it (R77a).
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
echo up >"$T/wg"
HEAD='zsnt=6 net=LTE-A_B3_(1800_MHz)_/_B1_(2100_MHz) pb=B3(1800MHz) s1=B1(2100MHz) rsrp=-85dBm rsrq=-14dB sinr=5.4dB rssi=-53dBm pci=157'

# line: one run, the newest line without its time stamp
line() {
    : >"$T/net-calls"
    lw-siglog
    # the handshake age is a clock reading: a second boundary under load must not fail the test
    tail -n 1 "$L" | cut -d' ' -f2- | sed 's/ wg_age=[0-9]*s/ wg_age=0s/'
}
# up KIND [FAMILY...]: the session and the paths that answer ("4" native or translated IPv4, "6" IPv6)
up() {
    _k=$1
    shift
    lw_session "$_k"
    lw_reach_none
    for _f in "$@"; do
        case $_f$_k in
            4v6clat) lw_reach 4 464-wwan_6_4 ;;
            4*) lw_reach 4 wwan0 ;;
            6*) lw_reach 6 wwan0 ;;
        esac
    done
}
no_ipv4_ping() {
    ! grep -q -- ' -4 \|1\.1\.1\.1' "$T/net-calls" || lw_fail "$1: an IPv4 ping: $(cat "$T/net-calls")"
}
no_ipv6_ping() {
    ! grep -q -- ' -6 \|::' "$T/net-calls" || lw_fail "$1: an IPv6 ping: $(cat "$T/net-calls")"
}

# R28, R77a: IPv4 only, the line it always was, with the fixture of lw_setup, without netifd's data of
# wwan and with it; one ping of 3 packets to 1.1.1.1 through wwan0
for data in seed none legacy v4; do
    case $data in
        seed) ;;
        legacy) lw_session legacy ;;
        none) rm -f "$T"/ifstatus/*.json ;;
        v4) lw_session v4 ;;
    esac
    lw_reach 4 wwan0
    lw_expect_eq "$(line)" "$HEAD loss=0% rtt=36.459 wg_age=0s" "R28 $data: IPv4-only line"
    lw_expect_eq "$(lw_pings)" 1 "R28 $data: one ping"
    lw_expect_grep "$T/net-calls" '^ping -4 -c 3 -W 2 -I wwan0 1\.1\.1\.1$'
    no_ipv6_ping "R77a $data"
    lw_reach_none
    lw_expect_eq "$(line)" "$HEAD loss=100% rtt=? wg_age=0s" "R28 $data: IPv4-only line, no answer"
    no_ipv6_ping "R77a $data, no answer"
    lw_reach_off
done

# D185: an answer over another interface is none
up v4
lw_reach 4 wg0
lw_reach 4 -
lw_expect_eq "$(line)" "$HEAD loss=100% rtt=? wg_age=0s" "R28: an answer through the tunnel"

# R28: dual stack appends loss6 and rtt6 after wg_age; IPv4 keeps loss and rtt
up dual 4 6
lw_expect_eq "$(line)" "$HEAD loss=0% rtt=36.459 wg_age=0s loss6=0% rtt6=21.500" "R28 dual: both answer"
lw_expect_grep "$T/net-calls" '^ping -4 -c 3 -W 2 -I wwan0 1\.1\.1\.1$'
lw_expect_grep "$T/net-calls" '^ping -6 -c 3 -W 2 -I wwan0 2606:4700:4700::1111$'
up dual 4
lw_expect_eq "$(line)" "$HEAD loss=0% rtt=36.459 wg_age=0s loss6=100% rtt6=?" "R28 dual: IPv6 lost"
up dual 6
lw_expect_eq "$(line)" "$HEAD loss=100% rtt=? wg_age=0s loss6=0% rtt6=21.500" "R28 dual: IPv4 lost"
up dual
lw_expect_eq "$(line)" "$HEAD loss=100% rtt=? wg_age=0s loss6=100% rtt6=?" "R28 dual: both lost"

# Terms, R28: a family of the session whose device is not ready failed; it is not absent, and IPv6
# does not take the place of IPv4 in `loss` and `rtt`
up dual 6
printf '{"up":false}\n' >"$T/ifstatus/wwan_4.json"
lw_expect_eq "$(line)" "$HEAD loss=100% rtt=? wg_age=0s loss6=0% rtt6=21.500" "R28 dual: wwan_4 is down"
no_ipv4_ping "R77a dual, wwan_4 down"
up v4 4
printf '{"up":false}\n' >"$T/ifstatus/wwan_4.json"
lw_expect_eq "$(line)" "$HEAD loss=0% rtt=36.459 wg_age=0s" "R28 v4: keep the modem's reading while DHCP is pending"
lw_expect_grep "$T/net-calls" '^ping -4 -c 3 -W 2 -I wwan0 1\.1\.1\.1$'
no_ipv6_ping "R77a v4, wwan_4 down"
for kind in v6child v6; do
    up "$kind" 6
    case $kind in
        v6child) printf '{"up":false}\n' >"$T/ifstatus/wwan_6.json" ;;
        v6) printf '{"up":true,"l3_device":"wwan0","data":{"cid_6":"18","pdh_6":"3203210530"}}\n' >"$T/ifstatus/wwan.json" ;;
    esac
    lw_expect_eq "$(line)" "$HEAD loss=100% rtt=? wg_age=0s" "R28 $kind: IPv6 pending, still the IPv6 reading"
    lw_expect_eq "$(lw_pings)" 0 "R77a $kind: nothing to ping yet"
done
up v6clat 6
printf '{"up":false}\n' >"$T/ifstatus/wwan_6_4.json"
lw_expect_eq "$(line)" "$HEAD loss=0% rtt=21.500 wg_age=0s" "R28 v6clat: the translation is not up, the line is the IPv6 one (R76a)"

# R28: IPv6 only, `loss` and `rtt` are those of IPv6, no loss6, no IPv4 ping
for kind in v6 v6child; do
    up "$kind" 6
    lw_expect_eq "$(line)" "$HEAD loss=0% rtt=21.500 wg_age=0s" "R28 $kind: IPv6-only line"
    ! grep -q -- ' -4 \|1\.1\.1\.1' "$T/net-calls" || lw_fail "R77a $kind: an IPv4 ping"
    up "$kind"
    lw_expect_eq "$(line)" "$HEAD loss=100% rtt=? wg_age=0s" "R28 $kind: IPv6-only line, no answer"
done

# R28, R76d: IPv6 with the translation has IPv4 service, so loss and rtt are of the IPv4 over the
# translation's device, and loss6 and rtt6 of the IPv6
up v6clat 4 6
lw_expect_eq "$(line)" "$HEAD loss=0% rtt=36.459 wg_age=0s loss6=0% rtt6=21.500" "R28 v6clat: both answer"
lw_expect_grep "$T/net-calls" '^ping -4 -c 3 -W 2 -I 464-wwan_6_4 1\.1\.1\.1$'
up v6clat 6
lw_expect_eq "$(line)" "$HEAD loss=100% rtt=? wg_age=0s loss6=0% rtt6=21.500" "R28 v6clat: the translation is down"

# the line is still one line per run, in the order and format of R28, with the tail after wg_age
lw_expect_eq "$(grep -c '' "$L")" "$(grep -c ' wg_age=' "$L")" "R28: every line has wg_age"
echo ok
