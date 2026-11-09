# R46a: the STATUS text. The R46 scenario word for word (failure since 14:20, step 3 of 6, class
# hang); the other classes, the limit reached, the 2G backup, no clock, no failure counted yet, no
# readings; one ASCII SMS of at most 160 characters in every case, also in the longest one.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
export LW_SMSCTL_MAX=1000
notify_setup 7.50
# shellcheck source=src/files/usr/lib/lw/common.sh
. /usr/lib/lw/common.sh
ADMIN=+48000000001
admins_set "$ADMIN"
passes 2

# rec_state CYCLES REBOOTS CLASS [PASSIVE]: what wwan-recover keeps while a failure lasts
rec_state() {
    printf 'cycles=%s\nreboots=%s\nclass=%s\npassive=%s\nuptime=900\n' "$1" "$2" "$3" "${4:-0}" \
        >/etc/wwan-recover.state
}
# status: ask by SMS, return the text of the newest reply (and check its form)
status() {
    sms_cmd "$ADMIN" STATUS
    _t=$(sms_body "$(sms_out)")
    [ "${#_t}" -le 160 ] || lw_fail "longer than 160 (${#_t}): $_t"
    [ -z "$(printf '%s' "$_t" | tr -d '\040-\176')" ] || lw_fail "not ASCII: $_t"
    case $_t in *'['* | *']'* | *'{'* | *'}'* | *"\\"* | *'^'* | *'|'* | *'~'* | *'`'*)
        lw_fail "a character that takes two septets: $_t" ;;
    esac
    printf '%s' "$_t"
}

lw_net down down
lw_uptime_set 1140

# --- the R46 scenario: failure from 14:20, 6 cycles, 2 restarts, class hang, asked at 14:52
wall_set '2026-11-07 14:20'
rec_state 1 0 hang
pass
wall_set '2026-11-07 14:25'
rec_state 2 0 hang
pass
wall_set '2026-11-07 14:52'
rec_state 7 2 hang
lw_expect_eq "$(status)" "Home router: internet DOWN since 14:20 (32 min). Self-repair step 3 of 6, cause: modem not responding. 2G backup: off." \
    "the R46 scenario"

# with a signal reading and a balance there is room for both
sig_line -86dBm 4.6dB
balance_asked
sms_in 50 1466 '11/07/26 14:00:00' 'Imate: 0.31 do 05.01.; '
passes 2
lw_expect_eq "$(status)" "Home router: internet DOWN since 14:20 (32 min). Self-repair step 3 of 6, cause: modem not responding. 2G backup: off. Signal fair. Balance 0.31 EUR (7 Nov)." \
    "signal and balance when they fit"

# --- the other classes and the limit
rec_state 7 1 account
case $(status) in
    *'Self-repair step 2 of 2, cause: package or credit used up. 2G backup: off.'*) ;;
    *) lw_fail "class account: $(sms_body "$(sms_out)")" ;;
esac
rec_state 7 0 sim
case $(status) in *'Self-repair step 1 of 2, cause: SIM card not ready.'*) ;; *) lw_fail "class sim" ;; esac
rec_state 7 1 unknown
case $(status) in *'step 2 of 6, cause: unknown.'*) ;; *) lw_fail "class unknown" ;; esac
rec_state 7 6 hang 1
case $(status) in
    *'Self-repair used up 6 restarts, cause: modem not responding. Unplug the router for 10 s. 2G backup: off.'*) ;;
    *) lw_fail "limit reached: $(sms_body "$(sms_out)")" ;;
esac
rec_state 7 2 account 1
case $(status) in *'used up 2 restarts, cause: package or credit used up.'*) ;; *) lw_fail "limit, account" ;; esac

# --- the 2G backup carries traffic: the 4G is down, the internet is slow
: >/tmp/lw-edge
echo 0,0,0 >"$T/modem/zsnt"
lw_net down up
rec_state 9 1 hang
case $(status) in
    "Home router: 4G DOWN since 14:20 (32 min), internet slow. Self-repair step 2 of 6, cause: modem not responding. 2G backup: on."*) ;;
    *) lw_fail "on 2G: $(sms_body "$(sms_out)")" ;;
esac
rm -f /tmp/lw-edge
echo 6,0,0 >"$T/modem/zsnt"
lw_net down down

# --- no clock: the length of the failure without a start; no failure counted yet; no state
ntp_off
rec_state 6 0 hang
lw_expect_eq "$(status)" "Home router: internet DOWN for 30 min. Self-repair step 1 of 6, cause: modem not responding. 2G backup: off. Signal fair. Balance 0.31 EUR (7 Nov)." \
    "no clock"
ntp_on
rm -f /etc/wwan-recover.state
lw_expect_eq "$(status)" "Home router: internet DOWN, the router is checking. Self-repair starts if it lasts. 2G backup: off. Signal fair. Balance 0.31 EUR (7 Nov)." \
    "offline, no failure counted"

# --- the longest case: a month of failure, limit reached, class account, a long balance
rm -f /etc/lw-notify/outage
rec_state 9000 2 account 1
long=$(status)
[ "${#long}" -gt 100 ] || lw_fail "the long case is not long: $long"
case $long in
    'Home router: internet DOWN since 7 Oct '*' (31 d 6 h). Self-repair used up 2 restarts'*) ;;
    *) lw_fail "long case: $long" ;;
esac
case $long in *'2G backup: off.'*) ;; *) lw_fail "2G state lost in the long case: $long" ;; esac

# --- OK: no readings at all, no clock, no network name
rm -f /etc/wwan-recover.state /tmp/lw-signal.log /etc/lw-notify/lastbal
lw_net up down
# the router has been on since 11:01 (the uptime must not go back, the service schedules by it)
echo $(($(date -u -d "2026-11-07 11:01:00" +%s) + $(lw_uptime))) >"$T/wall"
lw_expect_eq "$(status)" "Home router: internet OK, signal unknown. On since 7 Nov 11:01. Balance unknown." \
    "OK without readings"
ntp_off
case $(status) in 'Home router: internet OK, signal unknown. On for '*' min. Balance unknown.') ;; *) lw_fail "OK, no clock" ;; esac
# 3G name, poor signal
ntp_on
sig_line -110dBm 2dB WCDMA_B1 B1 ''
case $(status) in 'Home router: internet OK (3G), signal poor.'*) ;; *) lw_fail "3G, poor" ;; esac
echo ok
