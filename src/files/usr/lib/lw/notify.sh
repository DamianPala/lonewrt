# Telegram notifications (SPEC R34 to R38, D43 to D48): the code behind /usr/sbin/lw-notify.
# Sourced after /usr/lib/lw/common.sh. POSIX sh for busybox ash; every name has the nt_ prefix.
# shellcheck disable=SC2034,SC2153  # settings read by /usr/sbin/lw-notify; NT_CB* are set there
#
# Files: $NT_DIR on flash holds what must survive a reboot (keys of the SMS already handled, the
# send queue, the low-balance memory, the last known balance, the outage record) and is written
# only for a new SMS, a sent message, a changed balance, the start and end of an outage, its 2G
# message, a change of the 2G switch, the note of a restart asked in the chat, the one-time flag of
# the keyboard message and the DHCP names (at most once a day, devices.sh) (R34c, R37c, R37e, R40a,
# R44b, R45a). $NT_RUN in RAM holds the Bot API offset, the poll schedule, the link state, the reason of
# this boot, what the outage tracker saw since the boot and the restart question waiting for its
# answer.
# The bot token sits in the API URL only. Neither the URL nor uclient-fetch's stderr is ever
# logged or sent, so the token never reaches syslog or a reply (R34d).

NT_TAG=lw-notify
NT_DIR=${LW_NOTIFY_DIR:-/etc/lw-notify}
NT_RUN=${LW_NOTIFY_RUN:-/tmp/lw-notify}
NT_API=${LW_TG_API:-https://api.telegram.org}
# Clock for the schedule and the /balance windows; uptime, because the router has no RTC (D9)
NT_CLOCK=${LW_NOTIFY_CLOCK:-/proc/uptime}
NT_SIGLOG=/tmp/lw-signal.log
NT_EDGE=/tmp/lw-edge
NT_RECOVER_STATE=/etc/wwan-recover.state
# Wall clock in epoch seconds; tests move it through a file. There is no RTC (D9): the clock is
# right only after ntpd synced it. OpenWrt's own hotplug script 25-dnsmasqsec creates this RAM file
# on the first "stratum" event of busybox ntpd, which fires when it first syncs (it is how dnsmasq
# learns that DNSSEC dates are valid), and /var is RAM, so a reboot removes it again.
NT_WALL=${LW_NOTIFY_WALL:-}
NT_NTP=${LW_NOTIFY_NTP:-/var/state/dnsmasqsec}
NT_OUT=$NT_DIR/outage
NT_LASTBAL=$NT_DIR/lastbal
# Present = the 2G backup message is off (R37c); a reset or a new flash removes /etc/lw-notify
NT_NO2G=$NT_DIR/no-2g
# Who asked for the last restart from the chat, and when (R45a); present from the tap to the message
# after the boot
NT_RB=$NT_DIR/reboot
# Changes at every boot: tells a restart that happened from one that did not (R45a)
NT_BOOT_ID=${LW_NOTIFY_BOOT_ID:-/proc/sys/kernel/random/boot_id}
# Period of the recovery cron job: a failure cycle (R15)
NT_CYCLE=300
# Seconds; tests shorten them through the environment
NT_POLL=${LW_NOTIFY_POLL:-15}
NT_FULL_EVERY=${LW_NOTIFY_FULL_EVERY:-20}
NT_LONGPOLL=${LW_NOTIFY_LONGPOLL:-10}
NT_HTTP_LIMIT=${LW_NOTIFY_HTTP_LIMIT:-15}
NT_AT_LIMIT=${LW_NOTIFY_AT_LIMIT:-10}
NT_READ_LIMIT=${LW_NOTIFY_READ_LIMIT:-20}
NT_SEND_LIMIT=${LW_NOTIFY_SEND_LIMIT:-30}
NT_BALANCE_WAIT=${LW_NOTIFY_BALANCE_WAIT:-120}
NT_BALANCE_WINDOW=${LW_NOTIFY_BALANCE_WINDOW:-600}
NT_DOWN_GRACE=${LW_NOTIFY_DOWN_GRACE:-120}
# The restart question stands for this long (R45); the message after the boot waits for ntpd this
# long (uptime) before it gives the break as an estimate (R45a)
NT_RB_TTL=${LW_NOTIFY_REBOOT_TTL:-60}
NT_RB_WAIT=${LW_NOTIFY_REBOOT_WAIT:-120}
# Seconds from the tap to the kernel start (shutdown, bootloader); only used for the estimate of the
# break when the clock was not synced at one end, which has no RTC to measure it (D9)
NT_RB_GAP=40
# Bytes per bot reply; Telegram takes up to 4096 characters per message
NT_CHUNK=3500
NT_SEP='────────────'
# nt_help: the list of commands. The /balance line names the operator of the preset (R47); without
# a preset the check does not exist for this SIM (R47a).
nt_help() {
    if nt_preset_ok; then
        _hb="/balance – ask $NT_P_NAME for the balance (~1 min)"
    else
        _hb='/balance – the balance check is not available for this SIM'
    fi
    printf '%s\n' '/status – is the internet OK' \
        '/wifi – Wi-Fi name and password for guests' \
        '/devices – who is connected, data this month' \
        '/speedtest – measure the internet speed (~60 s)' \
        "$_hb" \
        '/sms – newest SMS (/sms 10 for more)' \
        '/alerts – automatic messages, on or off' \
        '/reboot – restart the router (asks to confirm)' \
        'The bot also posts every new SMS and a low-balance warning by itself.'
}
# An inline keyboard with no buttons: sent with an edited text, it removes the old buttons
NT_NOKB='&reply_markup=%7B%22inline_keyboard%22%3A%5B%5D%7D'
# Sent once after the first start of the image, and again after a reset or a new flash, which remove
# $NT_DIR (R37e, D64). The flag is written only after Telegram took the message.
NT_KB_FLAG=$NT_DIR/keyboard
# The reply keyboard (R37e, D64): 3 x 3, always shown, sized to its buttons. A press arrives as a
# normal message with the button's text, so every label stands for one command (NT_BUTTONS).
NT_KB='{"keyboard":[[{"text":"🟢 Status"},{"text":"📶 Wi-Fi"},{"text":"📱 Devices"}],
[{"text":"⚡ Speed"},{"text":"💶 Balance"},{"text":"✉️ SMS"}],
[{"text":"🔔 Alerts"},{"text":"🔄 Reboot"},{"text":"❓ Help"}]],
"is_persistent":true,"resize_keyboard":true}'
# label|command; read with the variation selector U+FE0F removed from both sides (nt_fe_strip)
NT_BUTTONS='🟢 Status|/status
📶 Wi-Fi|/wifi
📱 Devices|/devices
⚡ Speed|/speedtest
💶 Balance|/balance
✉️ SMS|/sms
🔔 Alerts|/alerts
🔄 Reboot|/reboot
❓ Help|/help'
# U+FE0F as the three bytes of its UTF-8 form: Telegram clients send an emoji such as the envelope
# with or without it, and a label must match either way
NT_FE=$(printf '\357\270\217')

# nt_lower TEXT: lower case for ASCII. busybox tr mangles [:upper:] (measured on 25.12.6:
# /Status -> /Statls), so the range is spelled out.
# shellcheck disable=SC2018,SC2019
nt_lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

# nt_digits TEXT: the digits of a phone number without a leading 00 (R46: "+48 000 000 001" and
# "0048000000001" are one number); the form a list entry and a reply number are kept in.
nt_digits() {
    printf '%s' "$1" | tr -cd '0-9' | sed 's/^00//'
}

# nt_core TEXT: the digits of a sender without a leading 00 or a single leading 0 (national form),
# the form compared against the end of a list entry (R46: 067000001 is the tail of +38267000001).
nt_core() {
    printf '%s' "$1" | tr -cd '0-9' | sed 's/^00//; t; s/^0//'
}

# nt_config: token, chat, threshold, router name and the SMS admins from uci. NT_TG is 1 with both token and chat
# (D43); NT_ADMINS lists the admin numbers as digits, space separated (R46). NT_SMS_AGE and
# NT_SMS_DAY are the REBOOT limits of R46b (minutes, restarts per day). Fails when neither channel
# is on, so the service does nothing at all (R38a, R46d). An entry with fewer than 6 digits is
# dropped (it could only match a short code such as 1466); one with 6 or 7 is kept, though no
# sender can match it (the sender needs 8 digits), so the init script and this test agree.
nt_config() {
    NT_TOKEN=$(uci -q get lonewrt.notify.token)
    NT_CHAT=$(uci -q get lonewrt.notify.chat)
    NT_LOW=$(uci -q get lonewrt.notify.low_balance)
    # the name that starts every SMS reply (R48); the profile requires one, the default is a net
    NT_NAME=$(uci -q get lonewrt.notify.router_name)
    NT_NAME=${NT_NAME:-Router}
    NT_TG=0
    [ -z "$NT_TOKEN" ] || [ -z "$NT_CHAT" ] || NT_TG=1
    NT_ADMINS=
    for _ae in $(uci -q get lonewrt.notify.sms_admins | tr ',' ' '); do
        _ar=$(printf '%s' "$_ae" | tr -cd '0-9')
        [ "${#_ar}" -ge 6 ] && [ "${#_ar}" -le 15 ] || continue
        NT_ADMINS="$NT_ADMINS $(nt_digits "$_ae")"
    done
    NT_SMS_AGE=$(nt_posint "$(uci -q get lonewrt.notify.sms_reboot_max_age)" 10)
    NT_SMS_DAY=$(nt_posint "$(uci -q get lonewrt.notify.sms_reboot_max_day)" 5)
    [ "$NT_TG" = 1 ] || [ -n "$NT_ADMINS" ]
}

# nt_posint VALUE DEFAULT: VALUE when it is a positive integer, else DEFAULT.
nt_posint() {
    case $1 in
        '' | *[!0-9]* | 0*) echo "$2" ;;
        *) echo "$1" ;;
    esac
}

nt_now() { cut -d. -f1 "$NT_CLOCK"; }

nt_wall() {
    if [ -n "$NT_WALL" ]; then head -n 1 "$NT_WALL"; else date +%s; fi
}

# nt_clock_ok: ntpd has synced the clock since the boot.
nt_clock_ok() { [ -f "$NT_NTP" ]; }

# nt_local EPOCH: "YYYY-MM-DD hh:mm" in the router's zone (date reads the uci system zone).
nt_local() { date -d "@$1" '+%Y-%m-%d %H:%M'; }

# nt_wallstr "MM/DD/YY hh:mm:ss": the modem's time as "20YY-MM-DD hh:mm" (the modem's own zone is
# the router's), empty when the time is missing.
nt_wallstr() {
    printf '%s\n' "$1" | awk '{ if (split($1, d, "/") == 3 && split($2, t, ":") >= 2)
        printf "20%s-%s-%s %s:%s\n", d[3], d[1], d[2], t[1], t[2] }'
}

# nt_when U|L "YYYY-MM-DD hh:mm": a time marker the sender turns into "Today 11:11" (U, capital)
# or "today 11:11" (L) at the moment of sending, so a message that waited in the queue past
# midnight still says the right day. No time gives "unknown".
nt_when() {
    case $2 in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9])
            printf '@@T%s:%s@@' "$1" "$2"
            ;;
        *) printf unknown ;;
    esac
}

# nt_resolve TEXT: the time markers as words. Today and yesterday only when the clock is right
# (ntpd synced it); otherwise the plain date, which is the modem's time and still true.
nt_resolve() {
    case $1 in
        *'@@T'*) ;;
        *)
            printf '%s\n' "$1"
            return 0
            ;;
    esac
    _t=$(nt_wall)
    _rel=0
    ! nt_clock_ok || _rel=1
    printf '%s\n' "$1" | awk -v today="$(date -d "@$_t" +%Y-%m-%d)" \
        -v yday="$(date -d "@$((_t - 86400))" +%Y-%m-%d)" -v rel="$_rel" '
        BEGIN { split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mon, " ") }
        {
            out = ""; rest = $0
            while (match(rest, /@@T[UL]:[0-9-]+ [0-9:]+@@/)) {
                kind = substr(rest, RSTART + 3, 1)
                d = substr(rest, RSTART + 5, 10)
                hm = substr(rest, RSTART + 16, 5)
                if (rel && d == today) w = "today " hm
                else if (rel && d == yday) w = "yesterday " hm
                else {
                    split(d, p, "-")
                    w = (p[3] + 0) " " mon[p[2] + 0] " "
                    if (rel && p[1] != substr(today, 1, 4)) w = w p[1] " "
                    w = w hm
                }
                if (kind == "U") w = toupper(substr(w, 1, 1)) substr(w, 2)
                out = out substr(rest, 1, RSTART - 1) w
                rest = substr(rest, RSTART + RLENGTH)
            }
            print out rest
        }'
}

# nt_span SECONDS: "12 min", "2 h 05 min", "3 d 4 h".
nt_span() {
    awk -v s="$1" 'BEGIN {
        m = int(s / 60 + 0.5); if (m < 1) m = 1
        if (m < 60) printf "%d min\n", m
        else if (m < 1440) printf "%d h %02d min\n", int(m / 60), m % 60
        else printf "%d d %d h\n", int(m / 1440), int(m % 1440 / 60) }'
}

# nt_get FILE [DEFAULT]: the integer in the first line of FILE (every state file holds one), or
# DEFAULT when FILE is missing or holds anything else, so a damaged file cannot stop the loop.
nt_get() {
    _v=$(head -n 1 "$1" 2>/dev/null)
    case ${_v#-} in
        '' | *[!0-9]*) echo "${2:-}" ;;
        *) echo "$_v" ;;
    esac
}

# nt_nap SECONDS: a sleep the TERM trap of the service loop can cut short.
nt_nap() {
    sleep "$1" &
    NT_NAP=$!
    wait "$NT_NAP"
    NT_NAP=
}

# nt_urlencode TEXT [ascii|raw]: application/x-www-form-urlencoded, byte by byte (busybox has no od).
# Telegram takes UTF-8 only (R34e). sms_tool prints the code points U+0080..U+00FF as one raw
# byte (Latin-1), so a byte that is not part of a valid UTF-8 sequence (RFC 3629: no overlong
# forms, no surrogates, nothing above U+10FFFF, no cut-off sequence) goes out as the UTF-8 of
# that code point; valid UTF-8 passes unchanged. Done here, at the last step, so the queue files
# and the SMS keys stay as they were read and every text the bot sends is covered. With "ascii"
# every character above U+007F, valid or not, becomes one "?" (R34f). With "raw" the same bytes come
# out as octal escapes (\ooo) for printf, which the parts of a long SMS use (multipart.sh).
nt_urlencode() {
    printf '%s' "$1" | hexdump -v -e '/1 "%02X\n"' | awk -v mode="${2:-}" '
        BEGIN {
            ascii = (mode == "ascii")
            raw = (mode == "raw")
            for (i = 0; i < 256; i++) v[sprintf("%02X", i)] = i
            for (i = 48; i < 58; i++) u[sprintf("%02X", i)] = sprintf("%c", i)
            for (i = 65; i < 91; i++) {
                u[sprintf("%02X", i)] = sprintf("%c", i)
                u[sprintf("%02X", i + 32)] = sprintf("%c", i + 32)
            }
            u["2D"] = "-"; u["2E"] = "."; u["5F"] = "_"; u["7E"] = "~"
        }
        function enc(h) { return (h in u) ? u[h] : "%" h }
        # one byte: percent-encoded, or as an octal escape for printf in "raw" mode
        function emit(c) {
            if (raw) printf "\\%03o", c
            else printf "%s", enc(sprintf("%02X", c))
        }
        function cont(j, lo, hi) { return j <= n && v[b[j]] >= lo && v[b[j]] <= hi }
        # length of the valid UTF-8 sequence starting at byte i, 0 when there is none: the lead
        # byte gives the length and the range of the second byte, the rest are 80..BF
        function seqlen(i,    c, len, lo, hi, k) {
            c = v[b[i]]
            if (c < 128) return 1
            lo = 128; hi = 191
            if (c >= 194 && c <= 223) len = 2
            else if (c >= 224 && c <= 239) {
                len = 3
                if (c == 224) lo = 160
                if (c == 237) hi = 159
            } else if (c >= 240 && c <= 244) {
                len = 4
                if (c == 240) lo = 144
                if (c == 244) hi = 143
            } else return 0
            if (!cont(i + 1, lo, hi)) return 0
            for (k = 2; k < len; k++) if (!cont(i + k, 128, 191)) return 0
            return len
        }
        { b[++n] = $1 }
        END {
            i = 1
            while (i <= n) {
                len = seqlen(i)
                if (len == 1 || (len > 1 && !ascii)) {
                    for (k = 0; k < len; k++) emit(v[b[i + k]])
                    i += len
                } else if (ascii) {
                    printf "?"
                    i += (len > 0) ? len : 1
                } else {
                    c = v[b[i]]
                    if (c < 192) {
                        emit(194)
                        emit(c)
                    } else {
                        emit(195)
                        emit(c - 64)
                    }
                    i++
                }
            }
        }'
}

# nt_api METHOD BODY [WAIT]: one Bot API call with a form-encoded BODY; the answer lands in
# NT_RESP. WAIT is the long-poll time, added to the limit, so a network that never answers ends
# the call within WAIT + NT_HTTP_LIMIT + 2 s and coreutils timeout leaves no process (R38).
# uclient-fetch prints "HTTP error 400" only without -q, and then its stderr also holds the URL
# with the token: the stderr goes to a file in RAM that is deleted at once, and only the status
# number leaves it (R34d). A 400 sets NT_REJECT=1: Telegram answered, so the link is fine and the
# link state does not change (R34f); any other failure is a link failure as before.
nt_api() {
    _limit=$((${3:-0} + NT_HTTP_LIMIT))
    _body=$NT_RUN/body.$$
    _err=$NT_RUN/err.$$
    printf '%s' "$2" >"$_body"
    (umask 077 && : >"$_err")
    NT_RC=0
    NT_REJECT=
    NT_RESP=$(timeout $((_limit + 2)) uclient-fetch -T "$_limit" -O - --post-file="$_body" \
        "$NT_API/bot$NT_TOKEN/$1" </dev/null 2>"$_err") || NT_RC=$?
    _http=$(sed -n 's/^HTTP error \([0-9][0-9]*\).*/\1/p' "$_err" | head -n 1)
    rm -f "$_body" "$_err"
    _ok=$(printf '%s\n' "$NT_RESP" | jsonfilter -e '@.ok' 2>/dev/null)
    if [ "$NT_RC" = 0 ] && [ "$_ok" = true ]; then
        nt_link_ok
        return 0
    fi
    if [ "$NT_RC" = 8 ] && [ "$_http" = 400 ]; then
        NT_REJECT=1
        nt_link_ok
        return 1
    fi
    [ "$NT_RC" != 0 ] || NT_RC=api
    nt_link_fail
    return 1
}

# nt_call METHOD TEXT [EXTRA]: sendMessage or editMessageText to the configured chat; EXTRA is more
# form fields, each starting with "&" (reply_markup, message_id). Returns 0 when it went out, 1 when
# it did not and should be tried again later, 2 when Telegram rejected it with a 400 also as plain
# ASCII, so a retry would never help (R34f). The EXTRA fields are ASCII, so they stay as they are.
nt_call() {
    _stx=$(nt_resolve "$2")
    nt_api "$1" "chat_id=$(nt_urlencode "$NT_CHAT")&text=$(nt_urlencode "$_stx")${3-}" && return 0
    [ -n "$NT_REJECT" ] || return 1
    nt_api "$1" "chat_id=$(nt_urlencode "$NT_CHAT")&text=$(nt_urlencode "$_stx" ascii)${3-}" &&
        return 0
    [ -n "$NT_REJECT" ] || return 1
    return 2
}

# nt_send TEXT [EXTRA]: one message to the chat; the id Telegram gave it is in NT_MSGID after a 0.
nt_send() {
    nt_call sendMessage "$1" "${2-}" || return
    # the message went out: a missing id must not turn that into a failure (and a resend)
    NT_MSGID=$(printf '%s\n' "$NT_RESP" | jsonfilter -e '@.result.message_id' 2>/dev/null) ||
        NT_MSGID=
}

# nt_edit MESSAGE_ID TEXT [EXTRA]: new text for a message of the bot; the buttons stay only when
# EXTRA brings them. A failure is not retried: the state the text describes has changed already.
# No ASCII copy on a 400 either: Telegram answers 400 to an edit that changes nothing (a double
# tap), and the copy would differ and replace the text with question marks.
nt_edit() {
    _etx=$(nt_resolve "$2")
    nt_api editMessageText \
        "chat_id=$(nt_urlencode "$NT_CHAT")&text=$(nt_urlencode "$_etx")&message_id=$1${3-}"
}

# nt_markup JSON: the reply_markup field for nt_send and nt_edit.
nt_markup() { printf '&reply_markup=%s' "$(nt_urlencode "$1")"; }

# nt_kb_markup: the reply_markup field with the keyboard of R37e.
nt_kb_markup() { nt_markup "$NT_KB"; }

# nt_fe_strip TEXT: TEXT without U+FE0F, in $NT_STRIP (a global, so the hot path forks nothing).
nt_fe_strip() {
    NT_STRIP=$1
    # an empty pattern would match forever
    [ -n "$NT_FE" ] || return 0
    while :; do
        case $NT_STRIP in
            *"$NT_FE"*) NT_STRIP=${NT_STRIP%%"$NT_FE"*}${NT_STRIP#*"$NT_FE"} ;;
            *) break ;;
        esac
    done
}

# The table once without U+FE0F, so a press is compared with one awk
nt_fe_strip "$NT_BUTTONS"
NT_BUTTONS_BARE=$NT_STRIP

# nt_button_cmd TEXT (R37e): the command of the button whose label is TEXT, empty for any other
# text. The label must be the whole message, bar white space around it and U+FE0F. With privacy
# mode off the bot sees every message of the group, so long text is dropped before any work.
nt_button_cmd() {
    [ "${#1}" -le 64 ] || return 0
    nt_fe_strip "$1"
    _bt=${NT_STRIP#"${NT_STRIP%%[![:space:]]*}"}
    _bt=${_bt%"${_bt##*[![:space:]]}"}
    [ -n "$_bt" ] || return 0
    printf '%s\n' "$NT_BUTTONS_BARE" |
        BTN_TEXT=$_bt awk -F'|' '$1 == ENVIRON["BTN_TEXT"] { print $2; exit }'
}

# nt_bot_name: the bot's own username in lower case, from getMe once per run (kept in RAM); empty
# while Telegram does not answer.
nt_bot_name() {
    if [ ! -s "$NT_RUN/botname" ]; then
        nt_api getMe '' || return 0
        nt_lower "$(printf '%s\n' "$NT_RESP" | jsonfilter -e '@.result.username' 2>/dev/null)" \
            >"$NT_RUN/botname"
    fi
    cat "$NT_RUN/botname"
}

# nt_kb_tick (R37e): the keyboard goes to the chat once after the first start of the image. Returns
# 1 when Telegram could not be reached, so the next pass tries again. The flag on flash is written
# after the send; a RAM copy keeps a full flash from turning one send into one per pass.
nt_kb_tick() {
    [ ! -e "$NT_KB_FLAG" ] && [ ! -e "$NT_RUN/keyboard" ] || return 0
    _kr=0
    nt_send "🤖 The router bot is ready. Tap a button below, or send /help to see what each one does." \
        "$(nt_kb_markup)" || _kr=$?
    [ "$_kr" != 1 ] || return 1
    : >"$NT_RUN/keyboard"
    [ "$_kr" = 0 ] ||
        lw_log "$NT_TAG" "Telegram rejected the keyboard message (HTTP 400), not sent again"
    mkdir -p "$NT_DIR"
    : | lw_write_atomic "$NT_KB_FLAG" || :
}

# nt_answer CALLBACK_ID [EXTRA]: answers a button tap, which stops the spinner on the button; EXTRA
# can carry a pop-up (&show_alert=true&text=...). The pop-up text is ASCII.
nt_answer() { nt_api answerCallbackQuery "callback_query_id=$(nt_urlencode "$1")${2-}"; }

# Link state: one syslog entry when sending stops working for NT_DOWN_GRACE s and one when it
# works again, nothing on ordinary passes (R34c).
nt_link_ok() {
    rm -f "$NT_RUN/fail_since"
    [ -f "$NT_RUN/down" ] || return 0
    rm -f "$NT_RUN/down"
    lw_log "$NT_TAG" "Telegram reachable again, $(nt_queued) SMS queued"
}

nt_link_fail() {
    _since=$(nt_get "$NT_RUN/fail_since")
    if [ -z "$_since" ]; then
        _since=$(nt_now)
        echo "$_since" >"$NT_RUN/fail_since"
    fi
    [ ! -f "$NT_RUN/down" ] || return 0
    [ $(($(nt_now) - _since)) -ge "$NT_DOWN_GRACE" ] || return 0
    : >"$NT_RUN/down"
    lw_log "$NT_TAG" "Telegram unreachable (error $NT_RC), $(nt_queued) SMS queued until it works"
}

# Queue: one file per message, $NT_DIR/queue/<6-digit sequence>-<SMS key>, sent in name order.
nt_queued() {
    find "$NT_DIR/queue" -type f ! -name '*.tmp.*' 2>/dev/null | wc -l
}

# nt_in_queue KEY: the message with KEY waits in the queue.
nt_in_queue() {
    for _f in "$NT_DIR"/queue/[0-9]*-"$1"; do
        [ -f "$_f" ] && return 0
    done
    return 1
}

# nt_enqueue KEY TEXT
nt_enqueue() {
    mkdir -p "$NT_DIR/queue"
    _last=0
    for _f in "$NT_DIR"/queue/[0-9]*; do
        case $_f in *.tmp.*) continue ;; esac
        [ -f "$_f" ] && _last=${_f##*/} && _last=${_last%%-*}
    done
    _last=${_last#"${_last%%[!0]*}"}
    printf '%s\n' "$2" | lw_write_atomic "$NT_DIR/queue/$(printf %06d $((${_last:-0} + 1)))-$1"
}

# nt_flush: send the queue in order and stop at the first failure. One flusher at a time (the
# service and the wwan hotplug), so no message goes out twice; a busy lock means another
# flusher is at it. A message leaves the queue only after Telegram confirmed it (R34a) or rejected
# it twice (R34f); a network failure or a 5xx/429 stops the loop and keeps it for the next pass.
nt_flush() {
    mkdir -p "$NT_RUN"
    (
        flock -n 8 || exit 0
        for _f in "$NT_DIR"/queue/[0-9]*; do
            [ -f "$_f" ] || continue
            case $_f in *.tmp.*) continue ;; esac
            nt_send "$(cat "$_f")"
            case $? in
                0) rm -f "$_f" ;;
                2)
                    # rejected as text and as ASCII: it would block the queue forever (R34f); no
                    # SMS text and nothing of the request goes into the log (R34d)
                    rm -f "$_f"
                    lw_log "$NT_TAG" "Telegram rejected a message (HTTP 400) twice, dropped it," \
                        "$(nt_queued) SMS still queued"
                    ;;
                *) exit 1 ;;
            esac
        done
    ) 8>"$NT_RUN/queue.lock"
}

# nt_fields JSON: one modem message into NT_IDX, NT_FROM, NT_TS, NT_TEXT and, for the part of a long
# SMS, NT_REF, NT_PART, NT_TOTAL (jsonfilter quotes the values for the shell).
nt_fields() {
    NT_IDX='' NT_FROM='' NT_TS='' NT_TEXT='' NT_REF='' NT_PART='' NT_TOTAL=''
    eval "$(printf '%s\n' "$1" | jsonfilter -e 'NT_IDX=@.index' -e 'NT_FROM=@.sender' \
        -e 'NT_TS=@.timestamp' -e 'NT_TEXT=@.content' -e 'NT_REF=@.reference' \
        -e 'NT_PART=@.part' -e 'NT_TOTAL=@.total' 2>/dev/null)"
}

# nt_sender SENDER (R39a): 9 or more digits get a "+", the short codes of the preset their operator
# (R47); without a preset there are no labels (R47a).
nt_sender() {
    [ -n "$1" ] || { echo unknown; return 0; }
    case " $NT_P_CODES " in
        *" $1 "*)
            echo "$NT_P_NAME $1"
            return 0
            ;;
    esac
    case $1 in
        *[!0-9]*) echo "$1" ;;
        *)
            if [ "${#1}" -ge 9 ]; then echo "+$1"; else echo "$1"; fi
            ;;
    esac
}

# nt_amount FROM TEXT (R47): the balance from the answer to the balance query, i.e. a message from
# the preset's sender whose first line fits its reply pattern ("Imate: 0.32 do 05.01.; "); empty for
# anything else and for a SIM without a preset. A comma becomes a dot.
nt_amount() {
    nt_preset_ok && [ "$1" = "$NT_P_FROM" ] || return 0
    printf '%s\n' "$2" | sed -n "1s#^[[:space:]]*$NT_P_RE.*#\\$NT_P_AREF#p" | tr , .
}

# nt_translate TEXT AMOUNT (R39b): "= Balance 0.31 EUR, credit valid until 5 Jan" for the answer to
# the balance query, in the currency of the preset; a pattern without a date gives no "until" part.
nt_translate() {
    if [ -z "$NT_P_DREF" ]; then
        printf '= Balance %s %s' "$2" "$NT_P_CUR"
        return 0
    fi
    _until=$(printf '%s\n' "$1" |
        sed -n "1s#^[[:space:]]*$NT_P_RE.*#\\$NT_P_DREF \\$NT_P_MREF#p" |
        awk 'NR == 1 { split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " ")
            if ($2 >= 1 && $2 <= 12 && $1 >= 1 && $1 <= 31) printf "%d %s", $1, m[$2 + 0] }')
    printf '= Balance %s %s, credit valid until %s' "$2" "$NT_P_CUR" "${_until:-unknown}"
}

# nt_format: the message in NT_FROM, NT_TS, NT_TEXT as the chat shows it (R39, R39a, R39b).
nt_format() {
    _fb=$NT_TEXT
    _fa=$(nt_amount "$NT_FROM" "$NT_TEXT")
    [ -z "$_fa" ] || _fb="$NT_TEXT
$(nt_translate "$NT_TEXT" "$_fa")"
    printf '✉️ %s · %s\n\n%s' "$(nt_sender "$NT_FROM")" "$(nt_when U "$(nt_wallstr "$NT_TS")")" \
        "$_fb"
}

# nt_below AMOUNT THRESHOLD: AMOUNT < THRESHOLD, compared in cents.
nt_below() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(int(a * 100 + 0.5) < int(b * 100 + 0.5)) }'
}

# nt_note_balance AMOUNT TS: the last known balance and the time it was read (the modem's time of
# the reply), on flash only when one of them changed (R34c, R39c).
nt_note_balance() {
    _nb="$1|$(nt_wallstr "$2")"
    [ "$(head -n 1 "$NT_LASTBAL" 2>/dev/null)" != "$_nb" ] || return 0
    # an older reading that turns up late (a backlog in the store) does not replace a newer one
    _nw=$(nt_wallstr "$2" | tr -cd 0-9)
    _no=$(head -n 1 "$NT_LASTBAL" 2>/dev/null | cut -d'|' -f2 | tr -cd 0-9)
    [ -z "$_nw" ] || [ -z "$_no" ] || [ "$_nw" -ge "$_no" ] || return 0
    mkdir -p "$NT_DIR"
    printf '%s\n' "$_nb" | lw_write_atomic "$NT_LASTBAL"
}

# nt_pick_balance AMOUNT TS: remembers the newest reply seen while the first run only records the
# store, so one write at the end gives /status a balance right after a flash.
nt_pick_balance() {
    _pw=$(nt_wallstr "$2" | tr -cd 0-9)
    [ "${_pw:-0}" -gt "$_pick_w" ] || return 0
    _pick_w=$_pw
    _pick_a=$1
    _pick_t=$2
}

# nt_low_text AMOUNT TS: the warning under a balance below the threshold (R36, R39).
nt_low_text() {
    printf '⚠️ Low balance: %s %s (%s)\nTop up at least %s %s, ' \
        "$1" "$NT_P_CUR" "$(nt_when L "$(nt_wallstr "$2")")" "$NT_LOW" "$NT_P_CUR"
    printf 'or the data package will not renew.'
}

# nt_balance KEY AMOUNT: the balance rule (R36). A reply goes to the chat when it answers a
# /balance from the last NT_BALANCE_WINDOW s, or when it is the first one below the threshold;
# every reading updates the below/above memory on flash, written only when it changes.
nt_balance() {
    _was=$(nt_get "$NT_DIR/balance" 0)
    _below=$_was
    if [ -n "$NT_LOW" ]; then
        _below=0
        nt_below "$2" "$NT_LOW" && _below=1
    fi
    nt_note_balance "$2" "$NT_TS"
    _warn=
    [ "$_below" = 1 ] && [ -n "$NT_LOW" ] && _warn="

$(nt_low_text "$2" "$NT_TS")"
    _req=$(nt_get "$NT_RUN/balance_req")
    if [ -n "$_req" ] && [ $(($(nt_now) - _req)) -le "$NT_BALANCE_WINDOW" ]; then
        rm -f "$NT_RUN/balance_req" "$NT_RUN/balance_late"
        nt_enqueue "$1" "$(nt_format)$_warn"
    elif [ -n "$_warn" ] && [ "$_was" != 1 ]; then
        nt_enqueue "$1" "$(nt_format)$_warn"
    fi
    [ "$_below" = "$_was" ] || printf '%s\n' "$_below" | lw_write_atomic "$NT_DIR/balance"
}

# nt_absorb JSON: the store as sms_tool lists it. Messages not handled before go to the queue (or
# the balance rule) first and into the seen list second, so a cut-off run neither loses nor
# doubles one. The first run after a flash or reset only records what is there (no backlog).
# The parts of a long SMS (R34g) are collected first and handled as one message by nt_mp_flush; the
# parts of a message still waiting for a missing part stay out of the seen list on flash, which is
# why _keys (every message in the store, for the count) and _seen (what is handled) are two lists.
nt_absorb() {
    mkdir -p "$NT_DIR"
    _keys=$NT_RUN/keys
    _seen=$NT_RUN/keys.seen
    : >"$_keys"
    : >"$_seen"
    : >"$_keys.new"
    rm -rf "$NT_MP"
    _first=0
    [ -f "$NT_DIR/seen" ] || _first=1
    # what the first scan of this run finds counts as old for a REBOOT (R46b)
    SC_OLD=0
    [ -f "$NT_RUN/sc_scanned" ] || SC_OLD=1
    _pick_a='' _pick_t='' _pick_w=0
    printf '%s\n' "$1" | jsonfilter -e '@.msg[*]' >"$NT_RUN/msgs"
    while IFS= read -r _m; do
        nt_fields "$_m"
        _k=$(printf '%s|%s|%s|%s' "$NT_IDX" "$NT_FROM" "$NT_TS" "$NT_TEXT" | md5sum | cut -c1-16)
        echo "$_k" >>"$_keys"
        if [ "$_first" = 1 ]; then
            echo "$_k" >>"$_seen"
            _amt=$(nt_amount "$NT_FROM" "$NT_TEXT")
            [ -z "$_amt" ] || nt_pick_balance "$_amt" "$NT_TS"
            continue
        fi
        if grep -qx "$_k" "$NT_DIR/seen"; then
            echo "$_k" >>"$_seen"
            continue
        fi
        if nt_mp_part; then
            # never a command (R34g); handled with the rest of its message by nt_mp_flush
            nt_mp_add "$NT_MP" "$_k"
            continue
        fi
        echo "$_k" >>"$_keys.new"
        echo "$_k" >>"$_seen"
        # a command is only noted here and runs after the seen list is on flash (sc_run), so a
        # REBOOT can never run twice
        sc_collect
        _amt=$(nt_amount "$NT_FROM" "$NT_TEXT")
        if [ "$NT_TG" != 1 ]; then
            # SMS control without Telegram: nothing is queued, the balance only feeds STATUS
            [ -z "$_amt" ] || nt_note_balance "$_amt" "$NT_TS"
            continue
        fi
        ! nt_in_queue "$_k" || continue
        if [ -n "$_amt" ]; then
            nt_balance "$_k" "$_amt"
        else
            nt_enqueue "$_k" "$(nt_format)"
        fi
    done <"$NT_RUN/msgs"
    nt_mp_flush
    [ -z "$_pick_a" ] || nt_note_balance "$_pick_a" "$_pick_t"
    wc -l <"$_keys" | tr -d ' ' >"$NT_RUN/count"
    _scan=1
    if [ "$_first" = 1 ] || [ -s "$_keys.new" ]; then
        # without the seen list on flash a command would run again after a restart, and the next
        # scan must still count as the first one (R46b)
        lw_write_atomic "$NT_DIR/seen" <"$_seen" || { rm -f "$NT_RUN/sc_todo"; _scan=0; }
    fi
    [ "$_scan" = 0 ] || : >"$NT_RUN/sc_scanned"
    rm -rf "$_keys" "$_seen" "$_keys.new" "$NT_RUN/msgs" "$NT_MP"
}

# nt_inbox: one inbox pass with at most one short AT command under the shared lock, never waiting
# for it (R34b): AT+CPMS? for the count, and the full list only in the pass after the count
# changed (or every NT_FULL_EVERY passes, for a deletion and an arrival in the same window).
nt_inbox() {
    if [ ! -f "$NT_RUN/need_recv" ]; then
        # a long SMS waits for a missing part (R34g): once its time is up, the list is read although
        # the count did not change
        _due=$(nt_get "$NT_RUN/mp_due")
        if [ -n "$_due" ] && [ "$(nt_now)" -ge "$_due" ]; then
            : >"$NT_RUN/need_recv"
            return 0
        fi
        _n=$(($(nt_get "$NT_RUN/passes" 0) + 1))
        echo "$_n" >"$NT_RUN/passes"
        if [ "$_n" -lt "$NT_FULL_EVERY" ]; then
            _out=$(lw_at_nowait "$NT_AT_LIMIT" 'AT+CPMS?') || return 0
            _c=$(printf '%s\n' "$_out" | sed -n 's/^+CPMS: *"ME",\([0-9]*\),.*/\1/p')
            [ -n "$_c" ] && [ "$_c" = "$(nt_get "$NT_RUN/count")" ] && return 0
        fi
        : >"$NT_RUN/need_recv"
        return 0
    fi
    _rc=0
    _json=$(timeout "$NT_AT_LIMIT" flock -n "$LW_AT_LOCK" sms_tool -d "$LW_AT_PORT" -s ME -j recv \
        </dev/null 2>/dev/null) || _rc=$?
    if [ "$_rc" != 0 ] || ! printf '%s\n' "$_json" | jsonfilter -e '@.msg' >/dev/null 2>&1; then
        # one quick retry (busy lock), then back to the count every NT_POLL s, so a failing or
        # hung modem does not get a list read every second (R34b); a timeout gets no retry
        _try=$(($(nt_get "$NT_RUN/need_recv" 0) + 1))
        [ "$_rc" != 124 ] || _try=2
        echo "$_try" >"$NT_RUN/need_recv"
        [ "$_try" -lt 2 ] || rm -f "$NT_RUN/need_recv"
        return 0
    fi
    rm -f "$NT_RUN/need_recv" "$NT_RUN/passes"
    nt_absorb "$_json"
    sc_run
}

# nt_sms_send NUMBER TEXT: the one place that sends an SMS (R27): the preset balance query and the
# replies to the SMS admins (R46), under the shared lock. Returns 0 when sent, else sms_tool's exit code (1 for
# a failure it reports in its output with a zero exit); NT_SEND_OUT holds what it printed. The
# 2025.08.23 build prints "sms sent sucessfully: N" or "sms not sent, code: N" (strings of the
# binary); its exit code on failure was not measured, so the output counts as well. That build
# encodes a "+" as one more digit (the network still answers +CMGS, the SMS reaches nobody; seen
# 2026-11-08), and it marks every number of 6 or more digits as international by itself.
nt_sms_send() {
    NT_SEND_RC=0
    NT_SEND_OUT=$(timeout "$NT_SEND_LIMIT" flock "$LW_AT_LOCK" \
        sms_tool -d "$LW_AT_PORT" send "${1#+}" "$2" </dev/null 2>&1) || NT_SEND_RC=$?
    if [ "$NT_SEND_RC" = 0 ]; then
        case $NT_SEND_OUT in
            *[Nn][Oo][Tt]\ [Ss][Ee][Nn][Tt]* | *[Ee][Rr][Rr][Oo][Rr]*) NT_SEND_RC=1 ;;
        esac
    fi
    return "$NT_SEND_RC"
}

# nt_balance_query: the balance query of the preset (R27, R47, D47). Fails without a preset; no SMS
# goes out then (R47a).
nt_balance_query() {
    nt_preset_ok || return 1
    nt_sms_send "$NT_P_QTO" "$NT_P_QTEXT"
}

# nt_weekly: the Monday balance check from cron (R35); without a threshold there is none (R36), and
# without a preset for the SIM nothing is sent (R47a).
nt_weekly() {
    [ -n "$NT_LOW" ] || return 0
    nt_preset_tick
    if ! nt_preset_ok; then
        lw_log "$NT_TAG" "weekly balance check skipped: no operator preset for this SIM"
        return 0
    fi
    _rc=0
    nt_balance_query || _rc=$?
    if [ "$_rc" = 0 ]; then
        lw_log "$NT_TAG" "weekly balance check: $NT_P_QTEXT sent to $NT_P_QTO"
    else
        lw_log "$NT_TAG" "weekly balance check: sending $NT_P_QTEXT to $NT_P_QTO failed (exit $_rc)"
    fi
}

# nt_balance_tick: tell the chat once when a /balance got no reply in NT_BALANCE_WAIT s; a late
# reply still counts until NT_BALANCE_WINDOW (R37).
nt_balance_tick() {
    _req=$(nt_get "$NT_RUN/balance_req")
    [ -n "$_req" ] || return 0
    _age=$(($(nt_now) - _req))
    if [ "$_age" -gt "$NT_BALANCE_WINDOW" ]; then
        rm -f "$NT_RUN/balance_req" "$NT_RUN/balance_late"
        return 0
    fi
    [ "$_age" -ge "$NT_BALANCE_WAIT" ] && [ ! -f "$NT_RUN/balance_late" ] || return 0
    nt_send "⏳ No answer from $NT_P_NAME yet (asked $_age s ago).
A later answer still comes here." && : >"$NT_RUN/balance_late"
}

# nt_recover_read: cycles, reboots, passive and class of the recovery script (read-only) into
# NT_RC_*; fails when there is no state file, which means no outage (R21c).
nt_recover_read() {
    NT_RC_CYCLES=0 NT_RC_REBOOTS=0 NT_RC_PASSIVE=0 NT_RC_CLASS=none
    [ -f "$NT_RECOVER_STATE" ] || return 1
    while IFS='=' read -r _rk _rv; do
        if [ "$_rk" = class ]; then
            case $_rv in sim | account | hang | unknown) NT_RC_CLASS=$_rv ;; esac
            continue
        fi
        case $_rv in '' | *[!0-9]*) continue ;; esac
        case $_rk in
            cycles) NT_RC_CYCLES=$_rv ;;
            reboots) NT_RC_REBOOTS=$_rv ;;
            passive) NT_RC_PASSIVE=$_rv ;;
        esac
    done <"$NT_RECOVER_STATE"
}

# nt_boot_reason: once per boot, at the first pass. A restart somebody asked for in the chat leaves
# its note on flash (R45a). Otherwise a restart with an unfinished failure that already used a
# self-repair reboot, and passive mode not yet reached, was the self-repair (R16, R19: in passive
# mode it no longer reboots); anything else is a power cut or a person (R39c). Kept in RAM, so it
# costs no flash write.
nt_boot_reason() {
    [ ! -f "$NT_RUN/boot_reason" ] || return 0
    if nt_rb_pending; then
        if [ "$(nt_rb_get via)" = sms ]; then
            printf 'restarted by SMS from %s\n' "$(nt_rb_get name)" >"$NT_RUN/boot_reason"
        else
            printf 'restarted from Telegram (%s)\n' "$(nt_rb_get name)" >"$NT_RUN/boot_reason"
        fi
        return 0
    fi
    nt_recover_read || :
    _why='power cut or manual restart'
    if [ "$NT_RC_CYCLES" -gt 0 ] && [ "$NT_RC_REBOOTS" -gt 0 ] && [ "$NT_RC_PASSIVE" = 0 ]; then
        _why='restarted by self-repair'
    fi
    printf '%s\n' "$_why" >"$NT_RUN/boot_reason"
}

# Outage record on flash, $NT_OUT, written at the start (when the failure reaches a second cycle,
# so one-cycle blips cost no write) and at the end (R40a). Keys: state=open|closed, start (epoch),
# ntp (clock right at the start), and once closed: dur (s), restarts, start_approx, dur_approx.
nt_rec_get() { sed -n "s/^$1=//p" "$NT_OUT" 2>/dev/null | head -n 1; }

# nt_outage_open: the failure reached its second cycle; start and clock state come from the first
# sighting kept in RAM.
nt_outage_open() {
    read -r _os _ons <"$NT_RUN/out_pending"
    printf 'state=open\nstart=%s\nntp=%s\n' "$_os" "$_ons" | lw_write_atomic "$NT_OUT"
    rm -f "$NT_RUN/out_pending"
}

# nt_outage_run: the recovery state shows a failure (cycles > 0). Remembers the largest cycle and
# reboot counts of this boot in RAM, notes the start at the first sighting.
nt_outage_run() {
    [ "$NT_RC_CYCLES" -le "$(nt_get "$NT_RUN/out_cycles" 0)" ] ||
        echo "$NT_RC_CYCLES" >"$NT_RUN/out_cycles"
    [ "$NT_RC_REBOOTS" -le "$(nt_get "$NT_RUN/out_reboots" -1)" ] ||
        echo "$NT_RC_REBOOTS" >"$NT_RUN/out_reboots"
    [ "$(nt_rec_get state)" != open ] || return 0
    if [ ! -f "$NT_RUN/out_pending" ]; then
        # a failure first seen already past its first cycle began before we looked (service
        # restart or reboot): its start is then estimated from the cycle count, as without NTP
        _ons=0
        if [ "$NT_RC_CYCLES" -le 1 ] && nt_clock_ok; then _ons=1; fi
        echo "$(nt_wall) $_ons" >"$NT_RUN/out_pending"
    fi
    [ "$NT_RC_CYCLES" -lt 2 ] || nt_outage_open
}

# nt_restarts_text N (R40): how the outage was fixed.
nt_restarts_text() {
    case $1 in
        0) echo 'fixed without a restart' ;;
        1) echo 'fixed by 1 restart' ;;
        '' | *[!0-9]*) echo 'restarts needed: unknown' ;;
        *) echo "fixed by $1 restarts" ;;
    esac
}

# nt_outage_close: the failure is over (the recovery state is gone) and the record is open: one
# "Internet back" message into the queue, then the record is closed. Duration and start are exact
# when the clock was right at both ends; otherwise the duration is the cycle count times the cron
# period, the start is counted back from now when the clock is right now, and both get a "~"
# (R40b). A reboot without a failure never gets here: there is no open record then.
nt_outage_close() {
    _cs=$(nt_rec_get start)
    # keyed on the stored start: a cut before the record is closed must not queue a second message
    _ck=out$_cs
    _cn=$(nt_rec_get ntp)
    _cc=$(nt_get "$NT_RUN/out_cycles" 0)
    _cr=$(nt_get "$NT_RUN/out_reboots" '?')
    _cw=$(nt_wall)
    case $_cs in '' | *[!0-9]*) _cs=$_cw _cn=0 ;; esac
    _sa=0 _da=0
    if [ "$_cn" = 1 ] && nt_clock_ok; then
        _cd=$((_cw - _cs))
    else
        _da=1
        _cd=$((_cc * NT_CYCLE))
        [ "$_cc" -gt 0 ] || _cd=$((_cw - _cs))
        if [ "$_cn" != 1 ]; then
            _sa=1
            ! nt_clock_ok || _cs=$((_cw - _cd))
        fi
    fi
    [ "$_cd" -ge 0 ] || _cd=0
    _tl=
    [ "$_sa" = 0 ] || _tl='~'
    _tw=
    [ "$_da" = 0 ] || _tw='~'
    nt_in_queue "$_ck" || nt_enqueue "$_ck" "🟢 Internet back after $_tw$(nt_span "$_cd")
Down since $_tl$(nt_when L "$(nt_local "$_cs")"), $(nt_restarts_text "$_cr")."
    printf 'state=closed\nstart=%s\ndur=%s\nrestarts=%s\nstart_approx=%s\ndur_approx=%s\n' \
        "$_cs" "$_cd" "$_cr" "$_sa" "$_da" | lw_write_atomic "$NT_OUT"
}

# nt_2g_on: the 2G backup message is switched on (the default).
nt_2g_on() { [ ! -e "$NT_NO2G" ]; }

# nt_edge_tick (R40c): the router is on the EDGE backup in an outage that the record already
# holds: one "slow" message per outage. The mark goes into the open record after the message is
# queued, so the second EDGE entry after a ladder reboot (the marker is RAM) stays quiet, and a
# cut between the two steps can only repeat the message, not lose it. Costs one flash write per
# outage that gets the message, none when the switch is off.
nt_edge_tick() {
    [ -e "$NT_EDGE" ] || return 0
    [ "$(nt_rec_get state)" = open ] || return 0
    [ "$(nt_rec_get edge)" != 1 ] || return 0
    nt_2g_on || return 0
    _es=$(nt_rec_get start)
    _en=$(nt_rec_get ntp)
    case $_es in '' | *[!0-9]*) return 0 ;; esac
    _et=
    if [ "$_en" != 1 ]; then
        _et='~'
        ! nt_clock_ok || _es=$(($(nt_wall) - NT_RC_CYCLES * NT_CYCLE))
    fi
    _ek=edge$(nt_rec_get start)
    nt_in_queue "$_ek" || nt_enqueue "$_ek" "🟠 Internet slow: switched to 2G backup
Messages and email OK, video and calls no.
4G down since $_et$(nt_when L "$(nt_local "$_es")"), the router keeps trying to bring it back.
(/alerts 2g off turns this message off)"
    printf 'state=open\nstart=%s\nntp=%s\nedge=1\n' "$(nt_rec_get start)" "$_en" |
        lw_write_atomic "$NT_OUT"
}

# nt_alerts_text: the automatic messages and whether each is on (R37).
nt_alerts_text() {
    _al=on
    [ -n "$NT_LOW" ] && nt_preset_ok || _al=off
    _a2=on
    nt_2g_on || _a2=off
    printf '🔔 Automatic messages\nNew SMS: on · Low balance: %s · Internet back: on · 2G backup: %s' \
        "$_al" "$_a2"
}

# nt_alerts_markup: the button under the list, which turns the 2G message the other way (R37d).
# The data names the state it asks for, so a tap on an old button cannot flip the switch back.
nt_alerts_markup() {
    if nt_2g_on; then
        nt_markup '{"inline_keyboard":[[{"text":"2G backup: turn off","callback_data":"al:2g:off"}]]}'
    else
        nt_markup '{"inline_keyboard":[[{"text":"2G backup: turn on","callback_data":"al:2g:on"}]]}'
    fi
}

# nt_2g_set on|off: the switch of the 2G message; the file is written only when the state changes
# (R37c).
nt_2g_set() {
    if [ "$1" = off ]; then
        if nt_2g_on; then
            mkdir -p "$NT_DIR"
            : >"$NT_NO2G"
        fi
    else
        ! [ -e "$NT_NO2G" ] || rm -f "$NT_NO2G"
    fi
}

# nt_alerts ARG1 ARG2 (R37c): "2g off" and "2g on" switch the 2G message and say so; anything else
# shows the list. Every answer carries the button (R37d).
nt_alerts() {
    _ahead=
    if [ "$1" = 2g ]; then
        case $2 in
            off | on)
                nt_2g_set "$2"
                _ahead="🔔 2G backup message is now $2.
"
                ;;
        esac
    fi
    nt_send "$_ahead$(nt_alerts_text)" "$(nt_alerts_markup)"
}

# nt_alerts_tap STATE (R37d): the button under the list; the same message shows the new state.
nt_alerts_tap() {
    nt_2g_set "$1"
    nt_answer "$NT_CB"
    nt_edit "$NT_CBMSG" "$(nt_alerts_text)" "$(nt_alerts_markup)" || :
}

# nt_outage_tick: one look at the recovery state per pass, read-only unless an outage starts or
# ends (R34c, R40, R40a). The state file exists exactly while a failure lasts (R21c).
nt_outage_tick() {
    nt_boot_reason
    if [ -f "$NT_RECOVER_STATE" ]; then
        nt_recover_read
        # a damaged file (no readable cycles) changes nothing
        [ "$NT_RC_CYCLES" -gt 0 ] || return 0
        nt_outage_run
        nt_edge_tick
        return 0
    fi
    if [ "$(nt_rec_get state)" = open ]; then
        mkdir -p "$NT_DIR"
        nt_outage_close
    fi
    rm -f "$NT_RUN/out_pending" "$NT_RUN/out_cycles" "$NT_RUN/out_reboots"
}
