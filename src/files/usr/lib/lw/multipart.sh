# Long SMS that arrive in parts (SPEC R34g, D67). sms_tool gives each part of one message the extra
# fields "reference", "part" and "total"; the parts of one message have the same sender and reference
# and can sit in the store in any order. Sourced by /usr/sbin/lw-notify after notify.sh. POSIX sh for
# busybox ash; every name has the nt_ prefix.
# shellcheck disable=SC2034  # NT_MP_* are read by lw-notify and notify.sh
#
# A part is stored as files under $DIR/<group>/: <part>.from .ts .text .key, "total" (the largest
# total any part names) and "keys" (every part key, also of a second copy of a part). The group is
# md5(sender|reference), so two long messages of one sender with other references stay apart.
# nt_mp_join builds the message from the parts present: each part passes the Latin-1 repair of R34e
# on its own before the join, so a stray byte at the end of one part cannot fuse with the start of
# the next into a character nobody sent.

# Seconds a group may wait for a missing part, counted from the first sight of its first part. The
# clock is the uptime in RAM, so a restart starts the wait again (the parts stay unhandled on flash).
NT_MP_WAIT=${LW_NOTIFY_MP_WAIT:-600}
# More parts than this is not a long SMS but garbage; such a message is forwarded as it is
NT_MP_MAX=20
NT_MP=$NT_RUN/mp
NT_MP_SMS=$NT_RUN/mps

# nt_mp_part: the message in NT_REF, NT_PART and NT_TOTAL is a part of a long SMS.
nt_mp_part() {
    case $NT_REF$NT_PART$NT_TOTAL in '' | *[!0-9]*) return 1 ;; esac
    [ -n "$NT_REF" ] && [ -n "$NT_PART" ] && [ -n "$NT_TOTAL" ] || return 1
    [ "$NT_TOTAL" -ge 2 ] && [ "$NT_TOTAL" -le "$NT_MP_MAX" ] || return 1
    [ "$NT_PART" -ge 1 ] && [ "$NT_PART" -le "$NT_TOTAL" ]
}

# nt_mp_add DIR KEY: the part in NT_FROM, NT_TS, NT_TEXT, NT_REF, NT_PART, NT_TOTAL into its group
# under DIR; the group id is left in NT_MP_GID. A second copy of a part adds only its key.
nt_mp_add() {
    NT_MP_GID=$(printf '%s|%s' "$NT_FROM" "$NT_REF" | md5sum | cut -c1-16)
    _mad=$1/$NT_MP_GID
    # the groups in the order their first part is listed in the store: the order of the messages
    if [ ! -d "$_mad" ]; then
        mkdir -p "$_mad"
        echo "$NT_MP_GID" >>"$1/order"
    fi
    echo "$2" >>"$_mad/keys"
    [ ! -e "$_mad/$NT_PART.key" ] || return 0
    printf '%s' "$NT_FROM" >"$_mad/$NT_PART.from"
    printf '%s' "$NT_TS" >"$_mad/$NT_PART.ts"
    printf '%s' "$NT_TEXT" >"$_mad/$NT_PART.text"
    echo "$2" >"$_mad/$NT_PART.key"
    [ "$NT_TOTAL" -le "$(nt_get "$_mad/total" 0)" ] || echo "$NT_TOTAL" >"$_mad/total"
}

# nt_utf8 TEXT: TEXT as valid UTF-8 (a byte outside a valid sequence becomes its code point, R34e),
# in NT_U8. Through printf and octal escapes because the result may hold new lines at its end.
nt_utf8() {
    _u8=$(nt_urlencode "$1" raw)
    # shellcheck disable=SC2059  # the format is nothing but \ooo escapes made by nt_urlencode
    NT_U8=$(printf "$_u8"; printf x)
    NT_U8=${NT_U8%x}
}

# nt_mp_join DIR GROUP: the message of a group in NT_FROM, NT_TS (of the first part present) and
# NT_TEXT (the parts in order, no separator, then one line "(part n of t missing)" for each missing
# part). NT_MP_MISSING lists the missing parts, NT_MP_KEY identifies the set of parts present.
nt_mp_join() {
    _mjd=$1/$2
    _mjt=$(nt_get "$_mjd/total" 2)
    NT_FROM='' NT_TS='' NT_TEXT='' NT_MP_MISSING='' _mjk=''
    _mjp=1
    while [ "$_mjp" -le "$_mjt" ]; do
        if [ -f "$_mjd/$_mjp.key" ]; then
            if [ -z "$NT_FROM$NT_TS" ]; then
                NT_FROM=$(cat "$_mjd/$_mjp.from")
                NT_TS=$(cat "$_mjd/$_mjp.ts")
            fi
            _mjx=$(cat "$_mjd/$_mjp.text"; printf x)
            nt_utf8 "${_mjx%x}"
            NT_TEXT=$NT_TEXT$NT_U8
            _mjk=$_mjk$(cat "$_mjd/$_mjp.key")
        else
            NT_MP_MISSING="$NT_MP_MISSING $_mjp"
        fi
        _mjp=$((_mjp + 1))
    done
    NT_MP_KEY=mp$(printf '%s' "$_mjk" | md5sum | cut -c1-14)
    for _mjp in $NT_MP_MISSING; do
        NT_TEXT="$NT_TEXT
(part $_mjp of $_mjt missing)"
    done
}

# nt_mp_flush: the groups collected in $NT_MP by nt_absorb. A complete one, or one whose first part
# was seen NT_MP_WAIT s ago, goes to the chat queue as one message and its part keys join the handled
# keys ($_keys.new, $_seen of nt_absorb); the others wait, their keys stay out of the seen list on
# flash, so a restart finds them again. The earliest end of a wait is left in $NT_RUN/mp_due for
# nt_inbox, which then reads the list once without a change of the message count.
nt_mp_flush() {
    rm -f "$NT_RUN/mp_due"
    mkdir -p "$NT_RUN/mp_first"
    _mfn=$(nt_now)
    for _mff in "$NT_RUN"/mp_first/*; do
        [ ! -e "$_mff" ] || [ -d "$NT_MP/${_mff##*/}" ] || rm -f "$_mff"
    done
    [ -f "$NT_MP/order" ] || return 0
    while IFS= read -r _mfg; do
        _mfs=$(nt_get "$NT_RUN/mp_first/$_mfg")
        if [ -z "$_mfs" ]; then
            _mfs=$_mfn
            echo "$_mfs" >"$NT_RUN/mp_first/$_mfg"
        fi
        nt_mp_join "$NT_MP" "$_mfg"
        _mfa=$((_mfn - _mfs))
        # shellcheck disable=SC2153  # NT_TG is set by nt_config in notify.sh
        if [ "$NT_TG" = 1 ] && [ -n "$NT_MP_MISSING" ] && [ "$_mfa" -lt "$NT_MP_WAIT" ]; then
            _mfe=$((_mfs + NT_MP_WAIT))
            _mfo=$(nt_get "$NT_RUN/mp_due")
            if [ -z "$_mfo" ] || [ "$_mfe" -lt "$_mfo" ]; then echo "$_mfe" >"$NT_RUN/mp_due"; fi
            continue
        fi
        # without a chat (SMS control alone) there is nothing to forward; a command never comes from
        # parts (R34g), so the parts are just handled
        if [ "$NT_TG" = 1 ] && ! nt_in_queue "$NT_MP_KEY"; then
            nt_enqueue "$NT_MP_KEY" "$(nt_format)"
        fi
        # shellcheck disable=SC2154  # _keys and _seen belong to the nt_absorb that called us
        cat "$NT_MP/$_mfg/keys" >>"$_keys.new"
        # shellcheck disable=SC2154
        cat "$NT_MP/$_mfg/keys" >>"$_seen"
        rm -f "$NT_RUN/mp_first/$_mfg"
    done <"$NT_MP/order"
}
