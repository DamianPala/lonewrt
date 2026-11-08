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

# lw_write_atomic FILE: stdin to FILE via a temp file and rename, so an interrupted write leaves
# either the old or the new content (SPEC R21c).
lw_write_atomic() {
    cat >"$1.tmp.$$" && mv -f "$1.tmp.$$" "$1"
}
