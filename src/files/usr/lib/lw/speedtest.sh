# Speed test of the bot (SPEC R41 to R41d, D54 to D56): the code behind /speedtest. Sourced by
# /usr/sbin/lw-notify after notify.sh. POSIX sh for busybox ash; every name has the nt_st_ prefix.
# shellcheck disable=SC2034  # the settings below are also read by /usr/sbin/lw-notify
#
# The service loop never waits for the test. /speedtest starts "lw-notify speedtest-run" as a
# process of its own (setsid: its own session, so one group kill reaches the timeout wrapper, the
# tool and the watchdog), and every pass of the loop looks for its result file. All state is in
# $NT_RUN (RAM): nothing here writes to flash or to syslog (R34c, R41b).
#
#   speedtest.pid     pid of the wrapper (= its process group), written by the service at the start
#   speedtest.start   line 1: the router's local time of the start, empty without a synced clock
#   speedtest.result  key=value lines from the worker, appears atomically when it is done
#   speedtest.msg     the message waiting for Telegram, with speedtest.msg.at (its uptime)
#   speedtest.last    the last good result of this boot: "YYYY-MM-DD hh:mm|down|up|ping" (R41b, D56)
#   speedtest.raw     what the tool printed last time, for a look when it fails (no token in it)
#
# "Running" is a live process, not a file: a pid file whose process is gone is only a leftover, so
# nothing a crash leaves behind can block the next test (R41c).

# Whole test: 80 s for the tool (it takes 40 s on the router) and up to 10 s for the ping after a
# failure, 100 s as the last resort; with the pass that picks the result up and one Telegram call
# the result is in the chat well inside the 120 s of R41
NT_ST_LIMIT=${LW_NOTIFY_ST_LIMIT:-80}
NT_ST_TOTAL=${LW_NOTIFY_ST_TOTAL:-100}
# How long a result waits for Telegram, and the long-poll cap while a test is on (the result is
# picked up at the next pass, so a 10 s poll would eat the margin)
NT_ST_KEEP=${LW_NOTIFY_ST_KEEP:-600}
NT_ST_POLL=${LW_NOTIFY_ST_POLL:-3}
NT_ST_STATS=${LW_NOTIFY_WWAN_STATS:-/sys/class/net/wwan0/statistics}

# nt_st_alive: the worker wrapper still runs. The command line is checked, so a pid that was reused
# by another program does not count (the match is on "lw-notify" and not on "speedtest-run": a
# pid whose fork has not exec'd yet still shows the service's own command line).
nt_st_alive() {
    _sp=$(nt_get "$NT_RUN/speedtest.pid")
    [ -n "$_sp" ] && grep -q lw-notify "/proc/$_sp/cmdline" 2>/dev/null
}

# nt_st_active: a test is running or its result has not reached the chat yet.
nt_st_active() {
    [ -f "$NT_RUN/speedtest.pid" ] || [ -f "$NT_RUN/speedtest.result" ] ||
        [ -f "$NT_RUN/speedtest.msg" ]
}

# nt_st_busy: a new test must wait.
nt_st_busy() {
    nt_st_alive || [ -f "$NT_RUN/speedtest.result" ] || [ -f "$NT_RUN/speedtest.msg" ]
}

# nt_st_kill: stop a running test with everything under it and forget it (service stop, start).
nt_st_kill() {
    if nt_st_alive; then
        # busybox kill takes "-PID" for a group only without "--"
        kill -TERM "-$_sp" 2>/dev/null || kill -TERM "$_sp" 2>/dev/null || :
    fi
    rm -f "$NT_RUN"/speedtest.pid "$NT_RUN"/speedtest.start "$NT_RUN"/speedtest.result* \
        "$NT_RUN"/speedtest.msg* "$NT_RUN"/speedtest.out "$NT_RUN"/speedtest.err
}

# nt_st_start: the worker, detached. NT_ST_WATCH is the service pid; the worker stops itself when
# that process is gone, whatever way it died (set by the service loop only).
nt_st_start() {
    rm -f "$NT_RUN"/speedtest.result* "$NT_RUN"/speedtest.msg*
    if nt_clock_ok; then
        nt_local "$(nt_wall)" >"$NT_RUN/speedtest.start"
    else
        : >"$NT_RUN/speedtest.start"
    fi
    # no --foreground here: at its limit the wrapper signals its whole group (worker, watchdog,
    # tool), not only the worker, whose death would leave the watchdog and the tool running
    setsid timeout -k 3 "$NT_ST_TOTAL" /usr/sbin/lw-notify speedtest-run \
        "${NT_ST_WATCH:-}" </dev/null >/dev/null 2>&1 &
    echo "$!" >"$NT_RUN/speedtest.pid"
}

# nt_speedtest_cmd (R41, R41c): the answer to /speedtest.
nt_speedtest_cmd() {
    if nt_st_busy; then
        nt_send "⏳ A speed test is already running, the result comes in a moment."
    elif [ -e "$NT_EDGE" ]; then
        nt_send "🟠 Speed test skipped: the router is on the slow 2G backup.
/status shows the details."
    else
        nt_st_start
        nt_send "⏱ Speed test started, result in about 60 s."
    fi
}

# nt_st_num VALUE: VALUE when it is a plain number, otherwise nothing.
nt_st_num() {
    case $1 in
        '' | *[!0-9.]* | *.*.* | .*) ;;
        *) printf '%s' "$1" ;;
    esac
}

# nt_st_txt VALUE: a name from the tool, as one short line without control characters.
nt_st_txt() {
    printf '%s' "$1" | tr -d '\000-\037\177' | cut -c1-60
}

# nt_st_int VALUE: whole number, rounded half up; nothing for a missing or non-numeric value.
nt_st_int() {
    [ -n "$(nt_st_num "$1")" ] || return 0
    awk -v v="$1" 'BEGIN { printf "%d\n", v + 0.5 }'
}

# nt_st_bytes: bytes seen by wwan0 so far (received + sent); nothing when unreadable.
nt_st_bytes() {
    _sb1=$(cat "$NT_ST_STATS/rx_bytes" 2>/dev/null) || return 0
    _sb2=$(cat "$NT_ST_STATS/tx_bytes" 2>/dev/null) || return 0
    [ -n "$(nt_st_num "$_sb1")" ] && [ -n "$(nt_st_num "$_sb2")" ] || return 0
    awk -v a="$_sb1" -v b="$_sb2" 'BEGIN { printf "%.0f\n", a + b }'
}

# nt_st_run WATCH (the worker, "lw-notify speedtest-run"): one run of the tool under a time limit,
# the data it used, and, when it fails, a plain ping. The result file is written once, at the end.
# The tool runs in the foreground of this process (timeout --foreground keeps it in our group), so
# a group kill of the wrapper takes everything down. WATCH is the service pid: a watchdog kills the
# group when that process is gone, because the service's own TERM handler can be late behind a
# long network call and a kill -9 runs none (R41d).
nt_st_run() {
    _swd=
    if [ -n "$1" ]; then
        _swg=$PPID
        (
            _sl=
            trap '[ -z "$_sl" ] || kill "$_sl" 2>/dev/null; exit 0' TERM
            while grep -q lw-notify "/proc/$1/cmdline" 2>/dev/null; do
                sleep 1 &
                _sl=$!
                wait "$_sl"
            done
            kill -TERM "-$_swg" 2>/dev/null
        ) &
        _swd=$!
    fi
    _sout=$NT_RUN/speedtest.out
    _serr=$NT_RUN/speedtest.err
    _sb0=$(nt_st_bytes)
    _src=0
    timeout --foreground -k 2 "$NT_ST_LIMIT" speedtest --output json </dev/null \
        >"$_sout" 2>"$_serr" || _src=$?
    _sb1=$(nt_st_bytes)
    # the banner, if any, is not JSON; the answer is the last line that starts with "{"
    _sj=$(grep '^[[:space:]]*{' "$_sout" 2>/dev/null | tail -n 1)
    _sdl=$(nt_st_num "$(printf '%s\n' "$_sj" | jsonfilter -e '@.download_mbit' 2>/dev/null)")
    {
        head -c 2000 "$_sout"
        head -c 500 "$_serr"
    } >"$NT_RUN/speedtest.raw" 2>/dev/null
    rm -f "$_sout" "$_serr"
    if [ "$_src" = 0 ] && [ -n "$_sdl" ]; then
        nt_st_write_ok "$_sj" "$_sdl" "$_sb0" "$_sb1"
    else
        nt_st_write_fail "$_src"
    fi
    if [ -n "$_swd" ]; then
        kill "$_swd" 2>/dev/null
        wait "$_swd" 2>/dev/null || :
    fi
}

# nt_st_jget JSON PATH: one value of the tool's JSON.
nt_st_jget() {
    printf '%s\n' "$1" | jsonfilter -e "@.$2" 2>/dev/null
}

# nt_st_write_ok JSON DOWNLOAD BYTES_BEFORE BYTES_AFTER
nt_st_write_ok() {
    _smb=
    if [ -n "$3" ] && [ -n "$4" ]; then
        _smb=$(awk -v a="$3" -v b="$4" \
            'BEGIN { if (b >= a) printf "%d\n", (b - a) / 1000000 + 0.5 }')
    fi
    {
        printf 'status=ok\ndl=%s\n' "$2"
        printf 'ul=%s\n' "$(nt_st_num "$(nt_st_jget "$1" upload_mbit)")"
        printf 'ping=%s\n' "$(nt_st_num "$(nt_st_jget "$1" ping)")"
        printf 'jitter=%s\n' "$(nt_st_num "$(nt_st_jget "$1" jitter)")"
        printf 'sponsor=%s\n' "$(nt_st_txt "$(nt_st_jget "$1" server.sponsor)")"
        printf 'city=%s\n' "$(nt_st_txt "$(nt_st_jget "$1" server.name)")"
        printf 'dist=%s\n' "$(nt_st_num "$(nt_st_jget "$1" server.distance)")"
        printf 'mb=%s\n' "$_smb"
    } | lw_write_atomic "$NT_RUN/speedtest.result"
}

# nt_st_write_fail EXIT: why it failed and whether the plain internet answers (R41c); the ping
# is the same check as the one behind /status.
nt_st_write_fail() {
    _sw=error
    case $1 in 124 | 137) _sw=timeout ;; esac
    _snp=down
    if nt_ping_try; then _snp=${NT_PING_MS:-up}; fi
    printf 'status=fail\nreason=%s\nnet_ping=%s\n' "$_sw" "$_snp" |
        lw_write_atomic "$NT_RUN/speedtest.result"
}

# nt_st_get KEY: a value of the result file.
nt_st_get() {
    sed -n "s/^$1=//p" "$NT_RUN/speedtest.result" 2>/dev/null | head -n 1
}

# nt_st_unit VALUE UNIT: "99 Mbit/s", or "unknown" when there is no number.
nt_st_unit() {
    _su=$(nt_st_int "$1")
    if [ -n "$_su" ]; then echo "$_su $2"; else echo unknown; fi
}

# nt_st_server: "Example ISP, Exampletown (7 km) · ~330 MB used"; the company form
# ("AD", "DOO") adds nothing for the reader.
nt_st_server() {
    _ssp=$(nt_st_get sponsor | sed -E 's/ +(AD|DOO|D\.O\.O\.|d\.o\.o\.|LLC|Ltd|Inc|GmbH)$//')
    _scy=$(nt_st_get city)
    _sdi=$(nt_st_int "$(nt_st_get dist)")
    _ssv=$_ssp
    if [ -n "$_scy" ]; then
        if [ -n "$_ssv" ]; then _ssv="$_ssv, $_scy"; else _ssv=$_scy; fi
    fi
    [ -z "$_sdi" ] || [ -z "$_ssv" ] || _ssv="$_ssv ($_sdi km)"
    printf 'Server: %s' "${_ssv:-unknown}"
    _smb=$(nt_st_get mb)
    [ -z "$_smb" ] || printf ' · ~%s MB used' "$_smb"
}

# nt_st_ok_text STAMP (R41a, R41b): the result message; "Previous today" only when the last good
# test was on the same day as this one.
nt_st_ok_text() {
    _sd=$(nt_st_int "$(nt_st_get dl)")
    if [ "$_sd" -ge 50 ]; then
        _sv=fast _se='✅ Enough for 4K video on several devices and video calls'
    elif [ "$_sd" -ge 10 ]; then
        _sv=OK _se='✅ Enough for HD video and video calls'
    elif [ "$_sd" -ge 2 ]; then
        _sv=slow _se='⚠️ Enough for browsing and low-quality video'
    else
        _sv='very slow' _se='❌ Enough for messages only'
    fi
    _sj=$(nt_st_get jitter)
    _sp=$(nt_st_unit "$(nt_st_get ping)" ms)
    [ "$_sp" = unknown ] || [ -z "$(nt_st_int "$_sj")" ] ||
        _sp="$_sp (jitter $(nt_st_int "$_sj") ms)"
    printf '🚀 Speed test: %s\n\n⬇️ Download: %s\n⬆️ Upload: %s\n📶 Ping: %s\n%s\n\n' "$_sv" \
        "$(nt_st_unit "$_sd" Mbit/s)" "$(nt_st_unit "$(nt_st_get ul)" Mbit/s)" "$_sp" "$_se"
    if nt_st_last && [ -n "$1" ] && [ "${NT_ST_AT%% *}" = "${1%% *}" ]; then
        printf 'Previous today: %s ⬇️ / %s ⬆️ (%s)\n' "$NT_ST_DL" "$NT_ST_UL" "${NT_ST_AT#* }"
    fi
    nt_st_server
}

# nt_st_fail_text: the failure message with the result of the plain ping (R41c).
nt_st_fail_text() {
    case $(nt_st_get reason) in
        timeout | gone) printf '❌ Speed test failed: it did not finish in time.\n' ;;
        *) printf '❌ Speed test failed: no speedtest.net server answered.\n' ;;
    esac
    _snp=$(nt_st_get net_ping)
    case $_snp in
        '') printf 'Try again later.' ;;
        down)
            printf 'The internet itself does not work either (no answer to ping), '
            printf 'try again later.'
            ;;
        up) printf 'The internet itself works, try again later.' ;;
        *) printf 'The internet itself works (ping %s ms), try again later.' "$_snp" ;;
    esac
}

# nt_st_collect: the finished test (or the worker that vanished without a result) becomes a
# message. A good result is remembered after the text is made, so "Previous" is the one before.
nt_st_collect() {
    _sst=$(head -n 1 "$NT_RUN/speedtest.start" 2>/dev/null)
    nt_now >"$NT_RUN/speedtest.msg.at"
    if [ ! -f "$NT_RUN/speedtest.result" ]; then
        printf 'status=fail\nreason=gone\n' >"$NT_RUN/speedtest.result"
    fi
    if [ "$(nt_st_get status)" = ok ]; then
        nt_st_ok_text "$_sst" | lw_write_atomic "$NT_RUN/speedtest.msg"
        if [ -n "$_sst" ]; then
            printf '%s|%s|%s|%s\n' "$_sst" "$(nt_st_int "$(nt_st_get dl)")" \
                "$(nt_st_int "$(nt_st_get ul)")" "$(nt_st_int "$(nt_st_get ping)")" |
                sed 's/||/|?|/g; s/|$/|?/' >"$NT_RUN/speedtest.last"
        fi
    else
        nt_st_fail_text | lw_write_atomic "$NT_RUN/speedtest.msg"
    fi
    rm -f "$NT_RUN/speedtest.result" "$NT_RUN/speedtest.pid" "$NT_RUN/speedtest.start"
}

# nt_st_tick: once per pass of the service loop, cheap when nothing is going on (R34c): pick up a
# finished test and send its message; a message Telegram does not take waits for the next pass
# and is dropped after NT_ST_KEEP s (a rejected one at once, R34f).
nt_st_tick() {
    nt_st_active || return 0
    if [ ! -f "$NT_RUN/speedtest.msg" ]; then
        if [ -f "$NT_RUN/speedtest.result" ] || ! nt_st_alive; then
            nt_st_collect
        else
            return 0
        fi
    fi
    _src=0
    nt_send "$(cat "$NT_RUN/speedtest.msg")" || _src=$?
    if [ "$_src" = 1 ] &&
        [ $(($(nt_now) - $(nt_get "$NT_RUN/speedtest.msg.at" 0))) -le "$NT_ST_KEEP" ]; then
        return 0
    fi
    rm -f "$NT_RUN"/speedtest.msg*
}

# nt_st_last: the last good test of this boot into NT_ST_AT (local time), NT_ST_DL, NT_ST_UL and
# NT_ST_PG; fails when there is none.
nt_st_last() {
    [ -f "$NT_RUN/speedtest.last" ] || return 1
    IFS='|' read -r NT_ST_AT NT_ST_DL NT_ST_UL NT_ST_PG <"$NT_RUN/speedtest.last"
    [ -n "$NT_ST_AT" ]
}

# nt_st_today STAMP: the time is from today by the router's clock (R41b). Without a synced clock
# nothing is "today".
nt_st_today() {
    [ -n "$1" ] && nt_clock_ok && [ "${1%% *}" = "$(nt_local "$(nt_wall)" | cut -d' ' -f1)" ]
}

# nt_st_status_line (R41b): a line for /status, with its own line break in front, only when the
# last good test of this boot was today; nothing otherwise, so the layout keeps no gap.
nt_st_status_line() {
    nt_st_last && nt_st_today "$NT_ST_AT" || return 0
    _spg="$NT_ST_PG ms"
    [ "$NT_ST_PG" != '?' ] || _spg=unknown
    printf '\n🚀 Speed test: %s ⬇️ / %s ⬆️ Mbit/s · ping %s (%s)' "$NT_ST_DL" "$NT_ST_UL" "$_spg" \
        "$(nt_when L "$NT_ST_AT")"
}
