# Operator presets (SPEC R47, R47a, D66): everything that belongs to one mobile operator (name, the
# balance query, the pattern of its answer, short-code labels, currency) lives in a data file
# /usr/share/lw/operators/<MCC-MNC>, picked by the first 5 digits of the SIM's IMSI. Sourced by
# /usr/sbin/lw-notify after notify.sh. POSIX sh for busybox ash; every name has the nt_ prefix.
# shellcheck disable=SC2034  # NT_P_* are read by the other notify files
#
# The file is parsed here as data and never run: KEY='value' lines, known keys only, values from a
# short list of safe characters, nothing is evaluated (docs/operators.md). A file that
# does not pass is rejected with one syslog line and the SIM is treated as one without a preset.
#
# NT_P_STATE: empty = the IMSI could not be read yet (tried again later), none = no usable preset
# (R47a), ok = the NT_P_* below are set. The 5 digits are kept in RAM ($NT_RUN/mccmnc), so a process
# of its own (the weekly job, "lw-notify once") does not ask the modem again; the service forgets
# them at its start, which is the moment a card swap shows up.

NT_OPERATORS=${LW_OPERATORS_DIR:-/usr/share/lw/operators}
# Seconds between two tries to read the IMSI while the modem does not give it
NT_PRESET_RETRY=${LW_NOTIFY_PRESET_RETRY:-60}
NT_P_STATE=
NT_MCC=
# Building blocks of the reply pattern, as sed BRE (docs/operators.md lists the same dialect)
NT_RE_AMOUNT='\([0-9][0-9]*\([.,][0-9][0-9]*\)\{0,1\}\)'
NT_RE_DAY='\([0-9]\{1,2\}\)'

# nt_p_chars VALUE CHARS MAXLEN: VALUE is not empty, at most MAXLEN bytes, and made only of CHARS
# (a tr set). The value is only ever data here: printf '%s', never a format, never evaluated.
nt_p_chars() {
    [ -n "$1" ] && [ "${#1}" -le "$3" ] || return 1
    [ -z "$(printf '%s' "$1" | tr -d "$2")" ]
}

# nt_p_set KEY VALUE: one line of a preset into NT_P_*; fails for an unknown key or a bad value.
nt_p_set() {
    case $1 in
        OPERATOR_NAME)
            nt_p_chars "$2" 'A-Za-z0-9 .-' 20 || return 1
            case $2 in [A-Za-z0-9]*) NT_P_NAME=$2 ;; *) return 1 ;; esac
            ;;
        CURRENCY)
            case $2 in [A-Z][A-Z][A-Z]) NT_P_CUR=$2 ;; *) return 1 ;; esac
            ;;
        BALANCE_QUERY_NUMBER)
            # digits, one optional leading +, at least 3 digits
            nt_p_chars "$2" '0-9+' 16 || return 1
            case ${2#+} in
                *[!0-9]*) return 1 ;;
                ??? | ????*) NT_P_QTO=$2 ;;
                *) return 1 ;;
            esac
            ;;
        BALANCE_QUERY_TEXT)
            # no leading "-": sms_tool would take the text for an option
            nt_p_chars "$2" 'A-Za-z0-9 .,:_-' 40 || return 1
            case $2 in [A-Za-z0-9]*) NT_P_QTEXT=$2 ;; *) return 1 ;; esac
            ;;
        BALANCE_REPLY_FROM)
            nt_p_chars "$2" 'A-Za-z0-9 .+_-' 16 || return 1
            case $2 in [A-Za-z0-9+]*) NT_P_FROM=$2 ;; *) return 1 ;; esac
            ;;
        BALANCE_REPLY_PATTERN)
            nt_p_chars "$2" 'A-Za-z0-9 :.,;/()=+{}_-' 80 || return 1
            NT_P_PAT=$2
            ;;
        SHORT_CODES)
            nt_p_chars "$2" 'A-Za-z0-9 ' 120 || return 1
            NT_P_CODES=$2
            ;;
        *) return 1 ;;
    esac
}

# nt_p_read FILE: FILE into NT_P_NAME, NT_P_CUR, NT_P_QTO, NT_P_QTEXT, NT_P_FROM, NT_P_PAT and
# NT_P_CODES. Fails with the reason (no value in it) in NT_P_ERR.
nt_p_read() {
    NT_P_NAME='' NT_P_CUR='' NT_P_QTO='' NT_P_QTEXT='' NT_P_FROM='' NT_P_PAT='' NT_P_CODES=''
    NT_P_ERR=''
    if [ "$(wc -c <"$1")" -gt 4096 ]; then
        NT_P_ERR='file larger than 4096 bytes'
        return 1
    fi
    _pn=0
    _pseen=' '
    while IFS= read -r _pl || [ -n "$_pl" ]; do
        _pn=$((_pn + 1))
        case $_pl in '' | '#'*) continue ;; esac
        case $_pl in
            [A-Z]*=\'*\') ;;
            *)
                NT_P_ERR="line $_pn: expected KEY='value'"
                return 1
                ;;
        esac
        _pk=${_pl%%=*}
        _pv=${_pl#*=}
        _pv=${_pv#\'}
        _pv=${_pv%\'}
        # the key is capitals and underscores, and no ' sits inside the value
        case $_pk in *[!A-Z_]*) _pv="'" ;; esac
        case $_pv in
            *\'*)
                NT_P_ERR="line $_pn: expected KEY='value'"
                return 1
                ;;
        esac
        case $_pseen in
            *" $_pk "*)
                NT_P_ERR="line $_pn: key $_pk appears twice"
                return 1
                ;;
        esac
        _pseen="$_pseen$_pk "
        if ! nt_p_set "$_pk" "$_pv"; then
            NT_P_ERR="line $_pn: unknown key or bad value for $_pk"
            return 1
        fi
    done <"$1"
    if [ -z "$NT_P_NAME" ] || [ -z "$NT_P_CUR" ] || [ -z "$NT_P_QTO" ] || [ -z "$NT_P_QTEXT" ] ||
        [ -z "$NT_P_FROM" ] || [ -z "$NT_P_PAT" ]; then
        NT_P_ERR='a required key is missing'
        return 1
    fi
}

# nt_p_compile PATTERN: the reply pattern as a sed regular expression in NT_P_RE, and the numbers
# of the groups that hold the amount, the day and the month (NT_P_AREF, NT_P_DREF, NT_P_MREF).
# Literal text matches itself, a space matches any white space (also none), {amount} is the balance
# with a dot or comma, {day} and {month} are 1 or 2 digits, {any} is any text. {amount} must be
# there once, {day} and {month} together or not at all. {any} may not be followed (after spaces) by
# {amount}, {day} or {month}. Fails for anything else in braces.
nt_p_compile() {
    _pc=$1
    _pn=0
    NT_P_RE='' NT_P_AREF='' NT_P_DREF='' NT_P_MREF=''
    while [ -n "$_pc" ]; do
        case $_pc in
            '{amount}'*)
                [ -z "$NT_P_AREF" ] || return 1
                NT_P_AREF=$((_pn + 1))
                _pn=$((_pn + 2))
                NT_P_RE=$NT_P_RE$NT_RE_AMOUNT
                _pc=${_pc#'{amount}'}
                ;;
            '{day}'*)
                [ -z "$NT_P_DREF" ] || return 1
                _pn=$((_pn + 1))
                NT_P_DREF=$_pn
                NT_P_RE=$NT_P_RE$NT_RE_DAY
                _pc=${_pc#'{day}'}
                ;;
            '{month}'*)
                [ -z "$NT_P_MREF" ] || return 1
                _pn=$((_pn + 1))
                NT_P_MREF=$_pn
                NT_P_RE=$NT_P_RE$NT_RE_DAY
                _pc=${_pc#'{month}'}
                ;;
            '{any}'*)
                NT_P_RE=$NT_P_RE'.*'
                _pc=${_pc#'{any}'}
                # greedy: {any} straight before a number would swallow its leading digits, so a
                # fixed word must sit between them
                _pr=$_pc
                while [ "${_pr# }" != "$_pr" ]; do _pr=${_pr# }; done
                case $_pr in '{amount}'* | '{day}'* | '{month}'*) return 1 ;; esac
                ;;
            '{'* | '}'*) return 1 ;;
            ' '*)
                NT_P_RE=$NT_P_RE'[[:space:]]*'
                _pc=${_pc#?}
                ;;
            .*)
                NT_P_RE=$NT_P_RE'\.'
                _pc=${_pc#?}
                ;;
            *)
                NT_P_RE=$NT_P_RE${_pc%"${_pc#?}"}
                _pc=${_pc#?}
                ;;
        esac
    done
    [ -n "$NT_P_AREF" ] || return 1
    # the date is both parts or none
    [ -n "$NT_P_DREF" ] && [ -n "$NT_P_MREF" ] || [ -z "$NT_P_DREF$NT_P_MREF" ]
}

# nt_p_clear: no preset.
nt_p_clear() {
    NT_P_NAME='' NT_P_CUR='' NT_P_QTO='' NT_P_QTEXT='' NT_P_FROM='' NT_P_PAT='' NT_P_CODES=''
    NT_P_RE='' NT_P_AREF='' NT_P_DREF='' NT_P_MREF=''
}

# nt_preset_load MCCMNC: the preset of this operator into NT_P_*. No file is a SIM without a preset
# (R47a). A file that is not valid says so once in syslog (marker in RAM, so a process of its own
# does not repeat it) and counts as no file.
nt_preset_load() {
    NT_MCC=$1
    NT_P_STATE=none
    nt_p_clear
    _pf=$NT_OPERATORS/$1
    [ -f "$_pf" ] && [ ! -e "$NT_RUN/preset_bad" ] || return 0
    if nt_p_read "$_pf" && nt_p_compile "$NT_P_PAT"; then
        NT_P_STATE=ok
        return 0
    fi
    [ -n "$NT_P_ERR" ] || NT_P_ERR='bad reply pattern'
    nt_p_clear
    : >"$NT_RUN/preset_bad"
    lw_log "$NT_TAG" "operator preset $1 rejected ($NT_P_ERR), treated as no preset"
}

# nt_preset_tick: until the preset is known, read the IMSI (at most every NT_PRESET_RETRY s, one
# short AT command that never waits for the lock) and load the preset of its first 5 digits.
nt_preset_tick() {
    [ -z "$NT_P_STATE" ] || return 0
    _pm=$(head -n 1 "$NT_RUN/mccmnc" 2>/dev/null)
    case $_pm in [0-9][0-9][0-9][0-9][0-9]) ;; *) _pm= ;; esac
    if [ -z "$_pm" ]; then
        _pl=$(nt_get "$NT_RUN/mccmnc_try")
        [ -z "$_pl" ] || [ $(($(nt_now) - _pl)) -ge "$NT_PRESET_RETRY" ] || return 0
        nt_now >"$NT_RUN/mccmnc_try"
        _pi=$(lw_imsi "$NT_AT_LIMIT" nowait) || return 0
        _pm=$(printf '%s' "$_pi" | cut -c1-5)
        echo "$_pm" >"$NT_RUN/mccmnc"
    fi
    nt_preset_load "$_pm"
}

# nt_preset_ok: the SIM has a usable preset.
nt_preset_ok() { [ "$NT_P_STATE" = ok ]; }

# nt_op_label: what the chat says for the operator, e.g. "Telekom".
nt_op_label() { printf '%s' "$NT_P_NAME"; }

# nt_na_line: the "no balance for this SIM" line of /status and /balance (R47a).
nt_na_line() {
    printf '💶 Balance: not available for this operator (%s)' "${NT_MCC:-unknown}"
}
