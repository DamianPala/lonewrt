# The router's own reading of "internet works" on every kind of link (R77, D173, D185): the verdict
# of /status (R39c), the SMS `status` reply (R46a), the 2G line (R40c) and the speed test's failure
# line (R41c). IPv4 only, dual stack, IPv6 only, IPv6 with the translation, IPv6 only through the child
# wwan_6. A link is online while one family answers through the session's own device; an answer that
# came over another interface is none; an IPv4-only link sees no IPv6 ping (R77a).
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
export LW_SMSCTL_MAX=1000
notify_setup 7.50
lw_uptime_set 1140
sig_line -86dBm 4.6dB
wifi_set 2 1
ADMIN=+48000000001
admins_set "$ADMIN"
passes 2

# up KIND [FAMILY...]: the session of that kind and which of its paths answer ("4" the native or
# translated IPv4, "6" the IPv6); no family = all it has
up() {
    _k=$1
    shift
    lw_session "$_k"
    lw_reach_none
    [ $# -gt 0 ] || case $_k in
        v4) set -- 4 ;;
        dual | v6clat) set -- 4 6 ;;
        *) set -- 6 ;;
    esac
    for _f in "$@"; do
        case $_f$_k in
            4v6clat) lw_reach 4 464-wwan_6_4 ;;
            4*) lw_reach 4 wwan0 ;;
            6*) lw_reach 6 wwan0 ;;
        esac
    done
}
status() {
    tg_push "$TG_CHAT" /status
    pass
    last_text
}
verdict() { status | head -n 1; }
status_sms() {
    sms_cmd "$ADMIN" STATUS
    sms_body "$(sms_out)"
}

OK='🟢 <b>Internet works</b>'
DOWN='🔴 <b>Internet does not work</b>'

for kind in v4 dual v6 v6clat v6child; do
    up "$kind"
    lw_expect_eq "$(verdict)" "$OK" "R39c, R77 $kind: verdict with the link up"
    case $(status_sms) in
        'Home router: internet OK'*) ;;
        *) lw_fail "R46a, R77 $kind: SMS reply with the link up: $(sms_body "$(sms_out)")" ;;
    esac
    lw_reach_none
    lw_expect_eq "$(verdict)" "$DOWN" "R39c, R77 $kind: verdict with the link down"
    case $(status_sms) in
        'Home router: internet DOWN'*) ;;
        *) lw_fail "R46a, R77 $kind: SMS reply with the link down: $(sms_body "$(sms_out)")" ;;
    esac
    # an answer over the tunnel, Tailscale or the LAN is none
    for dev in - wg0 tailscale0 br-lan; do
        lw_reach 4 "$dev"
        lw_reach 6 "$dev"
    done
    lw_expect_eq "$(verdict)" "$DOWN" "R77 $kind: an answer through another interface"
done

# one family is enough, whichever it is
for fam in 4 6; do
    up dual "$fam"
    lw_expect_eq "$(verdict)" "$OK" "R77: dual stack, only IPv$fam answers"
    up v6clat "$fam"
    lw_expect_eq "$(verdict)" "$OK" "R76d, R77: translation session, only IPv$fam answers"
done

# R40c: the 2G backup carries the traffic: online, so "slow", on an IPv6 session too
up v6
: >/tmp/lw-edge
lw_expect_eq "$(verdict)" "🟠 <b>Internet works, but slow (2G backup)</b>" "R40c, R77 v6: the 2G backup line"
lw_reach_none
lw_expect_eq "$(verdict)" "$DOWN" "R40c, R77 v6: the 2G backup without an answer"
rm -f /tmp/lw-edge

# R41c: the failure line of the speed test names the plain ping, the round trip of the first answer
# (IPv4 before IPv6)
failed() {
    st_mode fail
    st_run
    last_text
}
want_works() {
    printf '❌ Speed test failed: no speedtest.net server answered.\nThe internet itself works (ping %s ms), try again later.' "$1"
}
want_down() {
    printf '❌ Speed test failed: no speedtest.net server answered.\nThe internet itself does not work either (no answer to ping), try again later.'
}
up v4
lw_expect_eq "$(failed)" "$(want_works 36)" "R41c, R77 v4: ping of the IPv4 answer"
up dual
lw_expect_eq "$(failed)" "$(want_works 36)" "R41c, R77 dual: the IPv4 answer comes first"
up dual 6
lw_expect_eq "$(failed)" "$(want_works 22)" "R41c, R77 dual: only IPv6 answers"
up v6
lw_expect_eq "$(failed)" "$(want_works 22)" "R41c, R77 v6: ping of the IPv6 answer"
up v6clat 4
lw_expect_eq "$(failed)" "$(want_works 36)" "R41c, R76d: ping over the translation"
lw_reach_none
lw_expect_eq "$(failed)" "$(want_down)" "R41c, R77: nothing answers"

# R77a: the IPv4-only link had no IPv6 address pinged by any of this, and the other families no IPv4
# address when the session has none
: >"$T/net-calls"
up v4
verdict >/dev/null
status_sms >/dev/null
failed >/dev/null
! grep -q -- ' -6 \|::' "$T/net-calls" || lw_fail "R77a: an IPv6 ping on an IPv4-only link: $(cat "$T/net-calls")"
: >"$T/net-calls"
up v6
verdict >/dev/null
status_sms >/dev/null
failed >/dev/null
! grep -q -- ' -4 \|8\.8\.8\.8\|1\.1\.1\.1' "$T/net-calls" || lw_fail "R77a: an IPv4 ping on a link without IPv4 service: $(cat "$T/net-calls")"
echo ok
