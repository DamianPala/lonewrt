# Helpers for tests/notify/*.sh, sourced after /fw/tests/lib.sh. Not a test itself (no .sh suffix).
# shellcheck shell=sh

# shellcheck disable=SC2034  # used by the tests that source this file
TG_TOKEN='123456789:TESTtokq7x9-AAAAAAAAAAAAAAAAAAAAAAAAAAA'
TG_CHAT=-1001234567890
TG_OTHER=555000111
G=$LW_TEST/tg

# notify_setup [LOW_BALANCE]: lw_setup, the notify tests' stubs first on PATH, notifications configured
# for a group chat, Telegram up, the modem store empty. The service's clock is the test clock
# ($T/uptime), every pass polls the inbox, and the limits are short. The wall clock is
# 2026-11-07 11:20 UTC (zone UTC) and ntpd has synced it (ntp_on). The keyboard of the first start
# is marked as sent (kb_first_start undoes that).
notify_setup() {
    lw_setup
    PATH=/fw/tests/notify/stubs:$PATH
    uci -q set lonewrt.notify=notify
    uci -q set lonewrt.notify.token="$TG_TOKEN"
    uci -q set lonewrt.notify.chat="$TG_CHAT"
    [ -z "${1:-}" ] || uci -q set lonewrt.notify.low_balance="$1"
    uci -q set lonewrt.notify.router_name='Home router'
    uci -q commit lonewrt
    mkdir -p "$G/updates" "$G/sent"
    echo "$TG_TOKEN" >"$G/token"
    echo up >"$G/net"
    echo 100 >"$G/next_id"
    : >"$T/at-calls"
    export PATH LW_NOTIFY_CLOCK="$T/uptime" LW_NOTIFY_POLL=0 LW_NOTIFY_DOWN_GRACE=0 \
        LW_NOTIFY_HTTP_LIMIT=2 LW_NOTIFY_AT_LIMIT=2 LW_NOTIFY_READ_LIMIT=3 LW_NOTIFY_SEND_LIMIT=3 \
        LW_NOTIFY_WALL="$T/wall" LW_NOTIFY_WWAN_STATS="$T/wwan0" LW_NOTIFY_ST_LIMIT=5 \
        LW_NOTIFY_ST_TOTAL=12 LW_NOTIFY_ST_POLL=1 LW_NOTIFY_BOOT_ID="$T/boot_id" \
        LW_NOTIFY_LEASES="$T/leases" LW_NOTIFY_ARP="$T/arp"
    echo boot-0 >"$T/boot_id"
    # the keyboard message of the first start (R37e) is done: every test but keyboard.sh counts the
    # messages it caused itself
    mkdir -p /etc/lw-notify
    : >/etc/lw-notify/keyboard
    printf 'IP address HW type Flags HW address Mask Device\n' >"$T/arp"
    : >"$T/leases"
    wall_set '2026-11-07 11:20'
    ntp_on
    # the fake wwan0 counters and the speed test client's knobs (tests/notify/stubs/speedtest)
    mkdir -p "$T/wwan0" "$T/speedtest"
    echo 1000000000 >"$T/wwan0/rx_bytes"
    echo 500000000 >"$T/wwan0/tx_bytes"
}

# kb_first_start: the state of an image that has never run: no keyboard flag (R37e).
kb_first_start() { rm -f /etc/lw-notify/keyboard /tmp/lw-notify/keyboard; }

# reboot_sim [UPTIME]: lw_reboot_sim, and the kernel's boot id changes like at a real boot.
reboot_sim() {
    echo boot-$(($(sed 's/^boot-//' "$T/boot_id") + 1)) >"$T/boot_id"
    lw_reboot_sim "$@"
}

# wall_set "YYYY-MM-DD hh:mm" (UTC) / wall_add SECONDS: the wall clock the service reads.
wall_set() { date -u -d "$1:00" +%s >"$T/wall"; }
wall_add() { echo $(($(cat "$T/wall") + $1)) >"$T/wall"; }
# ntp_on / ntp_off: whether ntpd has synced the clock since the boot (OpenWrt's 25-dnsmasqsec file)
ntp_on() { mkdir -p /var/state && echo "ntpd says time is valid" >/var/state/dnsmasqsec; }
ntp_off() { rm -f /var/state/dnsmasqsec; }

# wifi_set N...: one Wi-Fi network per argument with that many associated devices; no argument
# removes the networks.
wifi_set() {
    rm -r -f "$T/wifi"
    mkdir -p "$T/wifi"
    _w=0
    for _n in "$@"; do
        _j='{"freq":2437,"clients":{'
        _i=0
        while [ "$_i" -lt "$_n" ]; do
            [ "$_i" = 0 ] || _j="$_j,"
            _j="$_j\"aa:bb:cc:00:0$_w:0$_i\":{\"auth\":true,\"assoc\":true,\"authorized\":true}"
            _i=$((_i + 1))
        done
        echo "$_j}}" >"$T/wifi/hostapd.phy$_w-ap0.json"
        _w=$((_w + 1))
    done
}

# wifi_client OBJECT FREQ MAC...: the stations hostapd lists for one network (OBJECT is e.g.
# hostapd.phy1-ap0, FREQ in MHz); a MAC written as MAC=noassoc is only authenticated, not associated.
wifi_client() {
    mkdir -p "$T/wifi"
    _o=$1
    _f=$2
    shift 2
    _j="{\"freq\":$_f,\"clients\":{"
    _sep=
    for _m in "$@"; do
        _a=true
        case $_m in *=noassoc) _a=false && _m=${_m%=noassoc} ;; esac
        _j="$_j$_sep\"$_m\":{\"auth\":true,\"assoc\":$_a,\"authorized\":true}"
        _sep=,
    done
    echo "$_j}}" >"$T/wifi/$_o.json"
}

# lease_set "MAC IP NAME"...: dnsmasq's lease file (a NAME of * is a device that sent none).
lease_set() {
    : >"$T/leases"
    for _l in "$@"; do
        set -f
        # shellcheck disable=SC2086  # splitting into MAC, IP and NAME is the point; NAME may be *
        set -- $_l
        set +f
        echo "1794000000 $1 $2 $3 01:$1" >>"$T/leases"
    done
}

# arp_set MAC...: neighbours of the LAN bridge in the ARP table (complete entries).
arp_set() {
    printf 'IP address       HW type     Flags       HW address            Mask     Device\n' >"$T/arp"
    _i=10
    for _m in "$@"; do
        printf '192.168.1.%s     0x1         0x2         %s     *        br-lan\n' "$_i" "$_m" >>"$T/arp"
        _i=$((_i + 1))
    done
}

# nlbw_set "MAC RX TX"...: the counters nlbwmon holds in memory (the daemon is running after this).
nlbw_set() {
    : >/tmp/nlbw-mem
    for _l in "$@"; do echo "$_l" >>/tmp/nlbw-mem; done
}

# sig_line RSRP SINR [NET [PB [S1]]]: a signal log line as lw-siglog writes it ("?" for no
# reading).
sig_line() {
    printf '2026-11-07_11:07:04 zsnt=6 net=%s pb=%s s1=%s rsrp=%s rsrq=-13dB sinr=%s ' \
        "${3:-LTE-A_B3_(1800_MHz)_/_B1_(2100_MHz)}" "${4:-B3(1800MHz)}" "${5:-B1(2100MHz)}" \
        "$1" "$2" >/tmp/lw-signal.log
    echo 'rssi=-55dBm pci=157 loss=0% rtt=49.904 wg_age=102s' >>/tmp/lw-signal.log
}

# sms_in INDEX SENDER TIMESTAMP CONTENT: a message arrives in the modem's ME store (no quotes or
# backslashes in CONTENT).
sms_in() {
    printf '{"index":%s,"sender":"%s","timestamp":"%s","content":"%s"}' "$1" "$2" "$3" "$4" \
        >"$T/modem/sms/$1.json"
}

# balance_asked: the router has just sent its balance query, so the next message that fits the
# operator's reply pattern counts as the balance (R36, D72); one that nobody asked for is an
# ordinary SMS. Same stamp as the weekly query and /balance leave.
balance_asked() {
    mkdir -p /tmp/lw-notify
    cut -d. -f1 "$T/uptime" >/tmp/lw-notify/balance_asked
}

# sms_part INDEX SENDER TIMESTAMP REFERENCE PART TOTAL CONTENT: one part of a long SMS arrives in the
# modem's ME store, with the extra fields sms_tool 2025.08.23 prints for it (R34g).
sms_part() {
    printf '{"index":%s,"sender":"%s","timestamp":"%s","reference":%s,"part":%s,"total":%s,"content":"%s"}' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" >"$T/modem/sms/$1.json"
}

# admins_set LIST: uci lonewrt.notify.sms_admins (empty = deleted, like the profile key); the numbers are
# fake (+48000000001 and so on)
admins_set() {
    if [ -n "$1" ]; then uci -q set lonewrt.notify.sms_admins="$1"; else uci -q delete lonewrt.notify.sms_admins || :; fi
    uci -q commit lonewrt
}

# sms_cmd SENDER TEXT [TIMESTAMP]: a new SMS arrives in the store and two passes read it (the
# count, then the list), so a command is answered when this returns. The store indexes run on. The
# default time is 11:21:00, a minute after the test clock starts.
sms_cmd() {
    # the index lives in a file: the helper is often called inside $( )
    _si=$(($(cat "$T/sms_idx" 2>/dev/null || echo 100) + 1))
    echo "$_si" >"$T/sms_idx"
    sms_in "$_si" "$1" "${3-11/07/26 11:21:00}" "$2"
    passes 2
}
# smsc_ts [SECONDS]: the SMSC time of now (SECONDS later, or earlier when negative) in the modem's
# format, for the zone of the test (UTC)
smsc_ts() { date -u -d "@$(($(cat "$T/wall") + ${1:-0}))" '+%m/%d/%y %H:%M:%S'; }
# sms_put SENDER TEXT [TIMESTAMP]: like sms_cmd, but no pass reads it (the message waits in the store).
sms_put() {
    _si=$(($(cat "$T/sms_idx" 2>/dev/null || echo 100) + 1))
    echo "$_si" >"$T/sms_idx"
    sms_in "$_si" "$1" "${3-11/07/26 11:21:00}" "$2"
}
# mv_fail SUFFIX / mv_ok: the rename of lw_write_atomic fails for a file whose path ends with
# SUFFIX (a full or read-only flash); everything else is the real mv.
mv_fail() {
    mkdir -p /opt/mvfail
    cat >/opt/mvfail/mv <<'MVEOF'
#!/bin/sh
for _a; do _dest=$_a; done
if [ -f /opt/mvfail/suffix ]; then
    case $_dest in *"$(cat /opt/mvfail/suffix)") exit 1 ;; esac
fi
exec /bin/busybox mv "$@"
MVEOF
    chmod +x /opt/mvfail/mv
    echo "$1" >/opt/mvfail/suffix
    case :$PATH: in *:/opt/mvfail:*) ;; *) PATH=/opt/mvfail:$PATH ;; esac
    export PATH
}
mv_ok() { rm -f /opt/mvfail/suffix; }
# sms_out: replies the modem was asked to send; sms_to N / sms_body N: number and text of the Nth.
sms_out() { if [ -f "$T/sms-sent" ]; then wc -l <"$T/sms-sent" | tr -d ' '; else echo 0; fi; }
sms_to() { sed -n "${1}p" "$T/sms-sent" | cut -d' ' -f1; }
sms_body() { sed -n "${1}p" "$T/sms-sent" | cut -d' ' -f2-; }
# reboots_n: how often the router was asked to restart
reboots_n() { grep -c '^reboot' "$T/events" || :; }

# tg_push CHAT TEXT: a chat message waiting on the fake Bot API (no quotes in TEXT).
tg_push() {
    _id=$(cat "$G/next_id")
    echo $((_id + 1)) >"$G/next_id"
    printf '{"update_id":%s,"message":{"message_id":%s,"from":{"id":42},' "$_id" "$_id" \
        >"$G/updates/$_id.json"
    printf '"chat":{"id":%s,"type":"supergroup"},"date":1790000000,"text":"%s"}}' "$1" "$2" \
        >>"$G/updates/$_id.json"
}

# tg_tap CHAT MSGID DATA [FIRST_NAME]: a tap on a button of message MSGID in CHAT (no quotes in the
# arguments); returns after setting TAP_ID to the callback id.
tg_tap() {
    _id=$(cat "$G/next_id")
    echo $((_id + 1)) >"$G/next_id"
    TAP_ID=cb$_id
    printf '{"update_id":%s,"callback_query":{"id":"cb%s","from":{"id":42,"is_bot":false,' "$_id" "$_id" \
        >"$G/updates/$_id.json"
    printf '"first_name":"%s"},"message":{"message_id":%s,"chat":{"id":%s,"type":"supergroup"},' \
        "${4-Alice}" "$2" "$1" >>"$G/updates/$_id.json"
    printf '"date":1790000000,"text":"old text"},"chat_instance":"x","data":"%s"}}' "$3" \
        >>"$G/updates/$_id.json"
}

# tg_migrate CHAT NEW: Telegram's service message when a group becomes a supergroup.
tg_migrate() {
    _id=$(cat "$G/next_id")
    echo $((_id + 1)) >"$G/next_id"
    printf '{"update_id":%s,"message":{"message_id":%s,"chat":{"id":%s,"type":"group"},' \
        "$_id" "$_id" "$1" >"$G/updates/$_id.json"
    printf '"date":1790000000,"migrate_to_chat_id":%s}}' "$2" >>"$G/updates/$_id.json"
}

# sent: number of messages the bot sent; sent_text N: the Nth one; last_text: the newest.
sent() { find "$G/sent" -name '*.text' | wc -l; }
sent_text() { cat "$G/sent/$1.text"; }
last_text() { sent_text "$(sent)"; }

# rejected_n: how many sendMessage calls the fake bot answered with HTTP 400 (tg/reject400);
# sendcalls: how many sendMessage calls it saw in all.
rejected_n() { if [ -f "$G/rejected" ]; then wc -l <"$G/rejected" | tr -d ' '; else echo 0; fi; }
sendcalls() { grep -c '^sendMessage$' "$G/calls" 2>/dev/null || :; }

# shown N: what message N shows now (its text after edits); markup_of N: its buttons as JSON.
shown() { cat "$G/sent/$1.shown"; }
markup_of() { cat "$G/sent/$1.markup"; }
# edits: how many editMessageText calls went through; edit_msgid K / edit_text K / edit_markup K.
edits() { find "$G/edits" -name '*.msgid' 2>/dev/null | wc -l | tr -d ' '; }
edit_msgid() { cat "$G/edits/$1.msgid"; }
edit_text() { cat "$G/edits/$1.text"; }
edit_markup() { cat "$G/edits/$1.markup"; }
# answers: how many answerCallbackQuery calls; answer_id K / answer_text K / answer_alert K.
answers() { find "$G/answers" -name '*.id' 2>/dev/null | wc -l | tr -d ' '; }
answer_id() { cat "$G/answers/$1.id"; }
answer_text() { cat "$G/answers/$1.text"; }
answer_alert() { cat "$G/answers/$1.alert"; }
# button_data MSGID N: the callback_data of the Nth button of message MSGID (1-based, row-major)
button_data() {
    markup_of "$1" | jsonfilter -e '@.inline_keyboard[*][*].callback_data' | sed -n "${2}p"
}

# expect_sent N: exactly N messages so far, all to the configured chat.
expect_sent() {
    lw_expect_eq "$(sent)" "$1" "messages sent"
    for _c in "$G"/sent/*.chat; do
        [ -f "$_c" ] || continue
        lw_expect_eq "$(cat "$_c")" "$TG_CHAT" "chat of ${_c##*/}"
    done
}

# expect_last TEXT: the newest message contains TEXT.
expect_last() {
    case $(last_text) in *"$1"*) ;; *) lw_fail "last message lacks '$1': $(last_text)" ;; esac
}

# pass: one service pass without waiting, 1 s later on the test clock. passes N: N of them (a new
# SMS needs two, R34b: the count, then the list).
pass() {
    lw_uptime_add 1
    wall_add 1
    lw-notify once
}
passes() {
    _i=0
    while [ "$_i" -lt "$1" ]; do
        pass
        _i=$((_i + 1))
    done
}

# st_json DL UL PING JITTER [SPONSOR [CITY [KM]]]: what the fake speed test client prints.
st_json() {
    {
        printf '{"client":{"ip":"203.0.113.7"},"servers_online":10,'
        printf '"server":{"name":"%s","id":5373,' "${6:-Springfield}"
        printf '"sponsor":"%s","distance":%s},"ping":%s,"jitter":%s,' \
            "${5:-Example Telecom AD}" "${7:-7}" "$3" "$4"
        printf '"download_mbit":%s,"upload_mbit":%s,"_":"all ok"}\n' "$1" "$2"
    } >"$T/speedtest/json"
}
# st_mode MODE [DELAY]: how the fake client behaves (see the stub's header).
st_mode() {
    echo "$1" >"$T/speedtest/mode"
    echo "${2:-0}" >"$T/speedtest/delay"
}
# st_calls: how often the fake client was started.
st_calls() {
    if [ -f "$T/speedtest/calls" ]; then wc -l <"$T/speedtest/calls" | tr -d ' '; else echo 0; fi
}
# st_wait: wait (at most 30 s) until the speed test worker has ended.
st_wait() {
    _i=0
    while pgrep -f 'lw-notify speedtest-run' >/dev/null && [ "$_i" -lt 30 ]; do
        sleep 1
        _i=$((_i + 1))
    done
    ! pgrep -f 'lw-notify speedtest-run' >/dev/null || lw_fail "the speed test worker did not end"
}
# st_run [CMD]: the command (default /speedtest) arrives, the worker runs to its end, the next
# pass sends the result: the chat gets "started" and then the result.
st_run() {
    tg_push "$TG_CHAT" "${1:-/speedtest}"
    pass
    st_wait
    pass
}
# no_orphans: no helper of the service left running (R12b, R38).
no_orphans() {
    ! pgrep -f 'sms_tool|uclient-fetch|flock /tmp/lw-at.lock|lw-notify' >/dev/null || {
        ps >&2
        lw_fail "orphaned process"
    }
}

# elapsed_since T0: seconds since T0 (date +%s).
elapsed_since() { echo $(($(date +%s) - $1)); }
