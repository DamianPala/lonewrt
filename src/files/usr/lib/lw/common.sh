# Shared helpers for the image's scripts. Sourced, never executed. POSIX sh for busybox ash.
# Tests override the LW_* paths; on the router the defaults apply.

LW_AT_PORT=${LW_AT_PORT:-/dev/ttyUSB2}
LW_AT_LOCK=${LW_AT_LOCK:-/tmp/lw-at.lock}
LW_UPTIME_FILE=${LW_UPTIME_FILE:-/proc/uptime}

# lw_at SECONDS COMMAND: one AT command on the scripts' port. The limit includes the wait for the
# shared lock (SPEC R12b): coreutils timeout kills flock together with sms_tool, measured on the
# router 2026-11-06 (exit 124, no orphan). Prints response lines without CR and blank lines.
# Returns 124 on timeout, otherwise the sms_tool exit code.
lw_at() {
    _lw_rc=0
    _lw_out=$(timeout "$1" flock "$LW_AT_LOCK" sms_tool -d "$LW_AT_PORT" at "$2" </dev/null 2>/dev/null) ||
        _lw_rc=$?
    printf '%s\n' "$_lw_out" | tr -d '\r' | sed '/^$/d'
    return "$_lw_rc"
}

# lw_at_nowait SECONDS COMMAND: like lw_at, but returns 75 at once when the lock is busy, for
# callers that must not wait on a modem suspected of hanging (SPEC R20a).
lw_at_nowait() {
    _lw_rc=0
    _lw_out=$(timeout "$1" flock -n "$LW_AT_LOCK" sms_tool -d "$LW_AT_PORT" at "$2" </dev/null 2>/dev/null) ||
        _lw_rc=$?
    [ "$_lw_rc" = 1 ] && [ -z "$_lw_out" ] && _lw_rc=75
    printf '%s\n' "$_lw_out" | tr -d '\r' | sed '/^$/d'
    return "$_lw_rc"
}

# lw_sms_list JSON: the message list of `sms_tool -j recv` on stdout, readable by jsonfilter, exit
# 0; exit 1 when it still is not. The tool prints the "sender" field as the network gave it, without
# escaping `"` and `\`, and a text sender ID may hold both, so one such message makes the whole list
# invalid JSON and stops everything that reads it (R34h, D71). Only that field is repaired, and only
# when the list is unreadable as it is, so a valid list passes unchanged. A sender cannot hold the
# 15 characters that end the field (`","timestamp":"`), so the first one after its start is the end,
# unless the start of the next entry comes first (a cut-off entry), and then the field is left
# alone. Its 19 characters (`{"index":` and `"sender":"`) do not fit in a sender of 11, its 10 do.
# The list is one record, because the GSM alphabet has a line break.
lw_sms_list() {
    if printf '%s\n' "$1" | jsonfilter -e '@.msg' >/dev/null 2>&1; then
        printf '%s\n' "$1"
        return 0
    fi
    _lw_fx=$(printf '%s\n' "$1" | awk '{ all = (NR > 1) ? all "\n" $0 : $0 }
    END {
        out = ""; rest = all
        while ((i = index(rest, "\"sender\":\"")) > 0) {
            out = out substr(rest, 1, i + 9)
            rest = substr(rest, i + 10)
            j = index(rest, "\",\"timestamp\":\"")
            if (j == 0) break
            s = substr(rest, 1, j - 1); e = ""
            # no boundary of its own (a cut-off entry): the next message must not be taken as its sender
            if (j > 64 || (index(s, "{\"index\":") > 0 && index(s, "\"sender\":\"") > 0)) continue
            for (k = 1; k <= length(s); k++) {
                c = substr(s, k, 1)
                if (c == "\"" || c == "\\") e = e "\\"
                e = e c
            }
            out = out e; rest = substr(rest, j)
        }
        print out rest }')
    printf '%s\n' "$_lw_fx"
    # jsonfilter's own exit code for a parse error is not 1
    printf '%s\n' "$_lw_fx" | jsonfilter -e '@.msg' >/dev/null 2>&1 || return 1
}

# lw_imsi SECONDS [nowait]: the SIM's IMSI (AT+CIMI through lw_at, so on the scripts' port under the
# shared lock, SPEC R12) on stdout; fails without a line of 6 to 15 digits. With "nowait" a busy lock
# fails at once (lw_at_nowait). The operator preset reads it this way (R47); /usr/lib/lw/lw-apn still
# has its own copy of the digit check, with its retry loop around it.
lw_imsi() {
    if [ "${2:-}" = nowait ]; then
        _lw_im=$(lw_at_nowait "$1" 'AT+CIMI') || return 1
    else
        _lw_im=$(lw_at "$1" 'AT+CIMI') || return 1
    fi
    _lw_im=$(printf '%s\n' "$_lw_im" | grep -E '^[0-9]{6,15}$' | head -n 1)
    [ -n "$_lw_im" ] || return 1
    printf '%s\n' "$_lw_im"
}

# lw_uptime: whole seconds since boot.
lw_uptime() {
    cut -d. -f1 "$LW_UPTIME_FILE"
}

# lw_log TAG MESSAGE: syslog entry at daemon.notice; with DRYRUN=1 marked and echoed (SPEC R21b).
lw_log() {
    _lw_tag=$1
    shift
    if [ "${DRYRUN:-0}" = 1 ]; then
        logger -t "$_lw_tag" -p daemon.notice "[DRY-RUN] $*"
        echo "[DRY-RUN] $*"
    else
        logger -t "$_lw_tag" -p daemon.notice "$*"
    fi
}

# lw_is_debug: true when the profile asked for detailed logs (uci lonewrt.log.level, R29c). The level
# is read once per process, which is enough for a service: a changed level takes effect at its next
# start. Tests may preset LW_LOG_LEVEL.
lw_is_debug() {
    [ -n "${LW_LOG_LEVEL+x}" ] || LW_LOG_LEVEL=$(uci -q get lonewrt.log.level)
    [ "$LW_LOG_LEVEL" = debug ]
}

# lw_debug TAG MESSAGE: like lw_log at daemon.debug, written only at the debug level (R29c).
lw_debug() {
    lw_is_debug || return 0
    _lw_tag=$1
    shift
    if [ "${DRYRUN:-0}" = 1 ]; then
        logger -t "$_lw_tag" -p daemon.debug "[DRY-RUN] $*"
    else
        logger -t "$_lw_tag" -p daemon.debug "$*"
    fi
}

# lw_write_atomic FILE: stdin to FILE via a temp file and rename, so an interrupted write leaves
# either the old or the new content (SPEC R21c).
lw_write_atomic() {
    cat >"$1.tmp.$$" && mv -f "$1.tmp.$$" "$1"
}
