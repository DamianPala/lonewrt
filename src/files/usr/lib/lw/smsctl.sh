# SMS control of the router (SPEC R46 to R46d, D61): an SMS with STATUS, REBOOT or HELP from a number
# in uci lonewrt.notify.sms_admins gets a one-SMS reply and, for REBOOT, a restart. Sourced by
# /usr/sbin/lw-notify after notify.sh and reboot.sh. POSIX sh for busybox ash; every name has the
# sc_ prefix. The status text uses the readings of /usr/sbin/lw-notify (nt_online, nt_sig, ...).
# shellcheck disable=SC2034,SC2153  # settings read by /usr/sbin/lw-notify; NT_* come from notify.sh
#
# The flow: nt_absorb notes a command of an admin (sc_collect) while it files the new messages,
# writes the list of handled messages to flash, and only then nt_inbox runs the notes (sc_run). A
# REBOOT therefore never runs twice: after the restart its message is on the handled list. The first
# pass after a flash or reset only records the store, so old commands do not run (R46).
# The reply counter (R46c) is a file on flash with one wall-clock time per reply, written only when
# a reply goes out. The replies are the only SMS besides the balance query (R27) and go through
# nt_sms_send.
# A REBOOT restarts only when it is fresh and under the daily limit (R46b, D65): a message the first
# scan of the service found in the modem is old, with a synced clock the SMSC time may be at most
# NT_SMS_AGE minutes old, and NT_SMS_DAY restarts per day are counted in a second file like the
# replies. Otherwise it gets a reply with the reason.

SC_TODO=$NT_RUN/sc_todo
# Replies over this window, in seconds: "10 replies in the last day" (R46c)
SC_LOG=$NT_DIR/sms-replies
SC_RLOG=$NT_DIR/sms-reboots
SC_MAX=${LW_SMSCTL_MAX:-10}
SC_WINDOW=${LW_SMSCTL_WINDOW:-86400}
# One SMS in the GSM 7-bit alphabet holds 160 septets (R46a)
SC_LEN=160
# Every reply starts with the router name of the profile, NT_NAME (R48), up to 20 characters. What a
# reply must say (the head, the short form of the repair step, the 2G state) is 153 characters at
# the very most with such a name and the longest times; the optional parts and the full form of the
# step are left out as a whole when they do not fit (sc_fit, sc_down_text), so no word is ever cut
# in two. sc_clean only guards the limit.

# sc_is_admin SENDER (R46, D65): SENDER without "+", a leading 00 or a single leading 0 has at least
# 8 digits and the end of an admin number. That number is left in SC_MATCH. A sender with no digits
# ("Telekom") and a short code never match. A foreign number with the same 8 or more final digits
# matches too; that is accepted.
sc_is_admin() {
    _scd=$(nt_core "$1")
    [ "${#_scd}" -ge 8 ] || return 1
    for _sca in $NT_ADMINS; do
        case $_sca in
            *"$_scd")
                SC_MATCH=$_sca
                return 0
                ;;
        esac
    done
    return 1
}

# sc_fresh TIMESTAMP: the SMSC time ("MM/DD/YY hh:mm:ss", the router's zone) is at most NT_SMS_AGE
# minutes before or after now; further ahead means the clocks or zones disagree, so the age says
# nothing. Without a synced clock there is nothing to compare with, so it passes; with one, a time
# that cannot be read does not.
sc_fresh() {
    nt_clock_ok || return 0
    _scts=$(printf '%s\n' "$1" | awk '{ if (split($1, d, "/") == 3 && split($2, t, ":") == 3)
        printf "20%s-%s-%s %s:%s:%s\n", d[3], d[1], d[2], t[1], t[2], t[3] }')
    [ -n "$_scts" ] || return 1
    _sce=$(date -d "$_scts" +%s 2>/dev/null) || return 1
    _sce=$(($(nt_wall) - _sce))
    [ "$_sce" -le $((NT_SMS_AGE * 60)) ] && [ "$_sce" -ge $((-NT_SMS_AGE * 60)) ]
}

# sc_kind CONTENT: status, reboot or help for exactly that word (any case, spaces around it), own for
# a text that starts with the router name, like our replies (two routers must not answer each other
# forever), else other.
sc_kind() {
    _sck=$(printf '%s' "$1" | tr '\r\n\t' '   ' | sed 's/^ *//; s/ *$//')
    case $(nt_lower "$_sck") in
        status) echo status ;;
        reboot) echo reboot ;;
        help) echo help ;;
        "$(nt_lower "$NT_NAME")"*) echo own ;;
        *) if sc_other_reply "$(nt_lower "$_sck")"; then echo own; else echo other; fi ;;
    esac
}

# The fixed starts of our own replies after "<name>: " (sc_status_text, sc_down_text, sc_reboot_text);
# the HELP reply is "<name> commands: status, reboot". One list for the loop guard (R48).
SC_OPENINGS='internet ok|internet down|4g down|reboot not done|restarting now'

# sc_other_reply TEXT (lower case): TEXT has the shape of a reply of a router with another name, so
# two routers with different names do not answer each other either.
sc_other_reply() {
    printf '%s\n' "$1" |
        grep -Eq "^[a-z0-9][a-z0-9 -]{0,19}(: ($SC_OPENINGS)| commands: status, reboot)"
}

# sc_collect: the message in NT_FROM, NT_TS and NT_TEXT is a command of an admin: note it for
# sc_run as "KIND NUMBER FLAG". NUMBER is where the reply goes: "+" and the admin number it matched,
# also for a sender in national form: the installed sms_tool marks every number of 6 or more digits
# as international (see nt_sms_send). FLAG says why a REBOOT is too old: start (found by the first scan of
# this run of the service) or age (SMSC time); ok otherwise.
sc_collect() {
    [ -n "$NT_ADMINS" ] || return 0
    sc_is_admin "$NT_FROM" || return 0
    _sck=$(sc_kind "$NT_TEXT")
    [ "$_sck" != own ] || return 0
    _scn=+$SC_MATCH
    _scf=ok
    if [ "$_sck" = reboot ]; then
        if [ "$SC_OLD" = 1 ]; then
            _scf=start
        elif ! sc_fresh "$NT_TS"; then
            _scf=age
        fi
    fi
    echo "$_sck $_scn $_scf" >>"$SC_TODO"
}

# sc_used FILE: entries of FILE (one wall-clock time each) in the last SC_WINDOW seconds. A time in
# the future (the clock went back) counts, so a wrong clock can only make a limit stricter.
sc_used() {
    [ -f "$1" ] || { echo 0; return 0; }
    awk -v lim=$(($(nt_wall) - SC_WINDOW)) \
        '$1 ~ /^[0-9]+$/ && $1 > lim { n++ } END { print n + 0 }' "$1"
}

# sc_note FILE: one more entry on flash, the counted ones of the window only (R46c). Written before
# the send or the restart, so a kill in the middle of it cannot lead to more than the limit.
sc_note() {
    mkdir -p "$NT_DIR"
    {
        awk -v lim=$(($(nt_wall) - SC_WINDOW)) '$1 ~ /^[0-9]+$/ && $1 > lim' "$1" 2>/dev/null
        nt_wall
    } | lw_write_atomic "$1"
}

# sc_clean TEXT: ASCII only, and without the characters that take two septets in GSM 7-bit, cut to
# one SMS (R46a).
sc_clean() {
    printf '%s' "$1" | tr '\n' ' ' | tr -cd ' -~' | sed 's/[][{}\^|~`]//g' | cut -c1-"$SC_LEN"
}

# sc_reply NUMBER TEXT: one SMS reply, unless the limit of the day is used up (R46c). A failed send
# leaves one syslog entry and is not tried again.
sc_reply() {
    if [ "$(sc_used "$SC_LOG")" -ge "$SC_MAX" ]; then
        if [ ! -e "$NT_RUN/sc_limit_logged" ]; then
            : >"$NT_RUN/sc_limit_logged"
            lw_log "$NT_TAG" \
                "SMS control: $SC_MAX replies in the last day, no more until one is a day old"
        fi
        return 0
    fi
    if ! sc_note "$SC_LOG"; then
        lw_log "$NT_TAG" "SMS control: the reply counter cannot be saved, no reply sent"
        return 0
    fi
    nt_sms_send "$1" "$(sc_clean "$2")" && return 0
    lw_log "$NT_TAG" "SMS control: reply not sent (exit $NT_SEND_RC: $(printf '%s' "$NT_SEND_OUT" |
        tr '\n' ' ' | tr -cd ' -~' | cut -c1-80))"
    return 1
}

# sc_stamp EPOCH [short]: "7 Nov 11:01" in the router's zone; with "short" only "11:01" for today.
sc_stamp() {
    _sct=$(nt_local "$(nt_wall)")
    nt_local "$1" | awk -v today="${_sct%% *}" -v short="${2:-}" '{
        split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " "); split($1, d, "-")
        if (short != "" && $1 == today) print $2
        else printf "%d %s %s\n", d[3], m[d[2] + 0], $2 }'
}

# sc_day "YYYY-MM-DD hh:mm": "7 Nov"; empty for anything else.
sc_day() {
    printf '%s\n' "$1" | awk '{
        split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " ")
        if (split($1, d, "-") == 3 && d[2] >= 1 && d[2] <= 12) printf "%d %s", d[3], m[d[2] + 0] }'
}

# sc_fit TEXT PART...: TEXT with each PART that still fits into one SMS appended, in order.
sc_fit() {
    _scf=$1
    shift
    for _scp in "$@"; do
        [ -n "$_scp" ] || continue
        [ $((${#_scf} + 1 + ${#_scp})) -gt "$SC_LEN" ] || _scf="$_scf $_scp"
    done
    printf '%s' "$_scf"
}

# sc_outage_secs: how long the failure lasts, in NT_RC_CYCLES cycles of the recovery script, or from
# the record of the notification service when it has the exact start (R40a).
sc_outage_secs() {
    _scs=$((NT_RC_CYCLES * NT_CYCLE))
    _sc0=$(nt_rec_get start)
    case $_sc0 in '' | *[!0-9]*) return 0 ;; esac
    if [ "$(nt_rec_get state)" = open ] && [ "$(nt_rec_get ntp)" = 1 ] && nt_clock_ok; then
        _scs=$(($(nt_wall) - _sc0))
    fi
    [ "$_scs" -ge 0 ] || _scs=0
}

# sc_cause: the class of the failure in words.
sc_cause() {
    case $NT_RC_CLASS in
        hang) echo 'modem not responding' ;;
        account) echo 'package or credit used up' ;;
        sim) echo 'SIM card not ready' ;;
        unknown) echo unknown ;;
        *) echo 'being checked' ;;
    esac
}

# sc_status_text (R46a): the state in one SMS. Internet OK: network, signal, since when it is on, the
# last balance. A failure: since when, the step of the self-repair with its limit, the cause, the 2G
# backup, then signal and balance when they fit.
sc_status_text() {
    nt_recover_read || :
    _sig=$(tail -n 1 "$NT_SIGLOG" 2>/dev/null)
    _scq=$(nt_rating "$(nt_num "$(nt_sig rsrp)")" "$(nt_num "$(nt_sig sinr)")")
    _scb=$(nt_bal_amount)
    if [ -n "$_scb" ]; then
        _scb="Balance $_scb $NT_P_CUR ($(sc_day "$(nt_bal_time)"))."
    else
        _scb='Balance unknown.'
    fi
    # a SIM without a preset has no balance to report (R47a)
    nt_preset_ok || _scb=''

    if nt_clock_ok; then
        _scu="On since $(sc_stamp $(($(nt_wall) - $(lw_uptime))))."
    else
        _scu="On for $(nt_span "$(lw_uptime)")."
    fi
    _scg='2G backup: off.'
    [ ! -e "$NT_EDGE" ] || _scg='2G backup: on.'
    _sco=0
    nt_online && _sco=1
    if [ "$_sco" = 1 ] && [ ! -e "$NT_EDGE" ]; then
        _scn=$(nt_netname "$(nt_sig net)")
        sc_fit "$NT_NAME: internet OK${_scn:+ ($_scn)}, signal $_scq." "$_scu" "$_scb"
        return 0
    fi
    sc_down_text "$_scq" "$_scg" "$_scb" "$_sco"
}

# sc_down_text SIGNAL BACKUP BALANCE ONLINE: the failure variant of sc_status_text (nt_recover_read
# is done). ONLINE 1 means the 2G backup carries traffic: the 4G is down, the internet is slow.
sc_down_text() {
    if [ "$4" = 1 ]; then _scw='4G DOWN'; else _scw='internet DOWN'; fi
    if [ "$NT_RC_CYCLES" -le 0 ]; then
        # no failure counted yet: the first cycle or the first minutes after the start
        _schead="$NT_NAME: $_scw, the router is checking."
        _scfull='Self-repair starts if it lasts.'
        _scshort=$_scfull
    else
        sc_outage_secs
        if nt_clock_ok; then
            _scw="$_scw since $(sc_stamp $(($(nt_wall) - _scs)) short) ($(nt_span "$_scs"))"
        else
            _scw="$_scw for $(nt_span "$_scs")"
        fi
        _schead="$NT_NAME: $_scw."
        [ "$4" != 1 ] || _schead="$NT_NAME: $_scw, internet slow."
        _sclim=6
        case $NT_RC_CLASS in account | sim) _sclim=2 ;; esac
        if [ "$NT_RC_PASSIVE" = 1 ]; then
            _scshort="Self-repair used up $_sclim restarts. Unplug the router for 10 s."
            _scfull="Self-repair used up $_sclim restarts, cause: $(sc_cause)."
            _scfull="$_scfull Unplug the router for 10 s."
        else
            _scstep=$((NT_RC_REBOOTS + 1))
            [ "$_scstep" -le "$_sclim" ] || _scstep=$_sclim
            _scshort="Self-repair step $_scstep of $_sclim."
            _scfull="Self-repair step $_scstep of $_sclim, cause: $(sc_cause)."
        fi
    fi
    # the cause is the first thing to go when the text does not fit one SMS
    _scz="$_schead $_scfull $2"
    [ "${#_scz}" -le "$SC_LEN" ] || _scz="$_schead $_scshort $2"
    # what is not known is not worth the characters here
    _scsg="Signal $1."
    [ "$1" != unknown ] || _scsg=
    _scbl=$3
    [ "$3" != 'Balance unknown.' ] || _scbl=
    sc_fit "$_scz" "$_scsg" "$_scbl"
}

# sc_reboot_text FLAG: SC_TEXT is the reply to a REBOOT and SC_GO says whether it restarts (1): a
# note that is too old or a day that is used up gets its reason and no restart (R46b, D65).
sc_reboot_text() {
    SC_GO=0
    case $1 in
        start)
            SC_TEXT="$NT_NAME: reboot not done, it was already waiting when the router started."
            SC_TEXT="$SC_TEXT Send it again."
            ;;
        age)
            SC_TEXT="$NT_NAME: reboot not done, the SMS is older than $NT_SMS_AGE min"
            SC_TEXT="$SC_TEXT or has no time. Send it again."
            ;;
        *)
            if [ "$(sc_used "$SC_RLOG")" -ge "$NT_SMS_DAY" ]; then
                SC_TEXT="$NT_NAME: reboot not done, $NT_SMS_DAY restarts by SMS in the last day."
                SC_TEXT="$SC_TEXT Try again later."
            else
                SC_GO=1
                SC_TEXT="$NT_NAME: restarting now, back in about 2 min."
            fi
            ;;
    esac
}

# sc_run: run the notes of sc_collect, one reply each; a REBOOT that may restart does so after its
# reply, also when the limit of replies is used up (R46b, R46c).
sc_run() {
    [ -s "$SC_TODO" ] || return 0
    # the seen list must be on flash before a command runs: the overlay writes back later, and a
    # power cut after the reply to a restart command would run it again at the next start
    sync
    _srto=
    while read -r _srk _srn _srf <&3; do
        case $_srk in
            status) _srt=$(sc_status_text) ;;
            reboot)
                sc_reboot_text "$_srf"
                _srt=$SC_TEXT
                [ "$SC_GO" != 1 ] || _srto=$_srn
                ;;
            *) _srt="$NT_NAME commands: status, reboot" ;;
        esac
        sc_reply "$_srn" "$_srt" || :
    done 3<"$SC_TODO"
    rm -f "$SC_TODO"
    [ -z "$_srto" ] || sc_reboot "$_srto"
}

# sc_reboot NUMBER (R46b): the restart is counted on flash first; when that fails the restart does
# not happen, or the daily limit would mean nothing. Then the note for the message after the start
# (only when the chat exists) and the restart. The syslog entry has no number.
sc_reboot() {
    if ! sc_note "$SC_RLOG"; then
        lw_log "$NT_TAG" "SMS control: the restart counter cannot be saved, no restart"
        return 0
    fi
    lw_log "$NT_TAG" "SMS command REBOOT accepted, restarting the router"
    [ "$NT_TG" != 1 ] || nt_rb_record "$1" sms
    nt_rb_go
}
