# Names the owner gives to devices from the chat (SPEC R50, R50a, D87 to D89): the button under
# /devices, the list of devices to pick from, the reply that carries the name, and the file on flash.
# Sourced by /usr/sbin/lw-notify after devices.sh. POSIX sh for busybox ash; every name has the nt_nm_
# prefix.
# shellcheck disable=SC2153  # NT_* are set by notify.sh and /usr/sbin/lw-notify
#
# The flow: "✏️ Name a device" under /devices -> a message with one button per device (NT_NM_PICK,
# in RAM: its message id, the uptime of the ask, the MACs it offered) -> a tap on a device -> a prompt
# that asks for the name as a reply (NT_NM_ASKS, in RAM: prompt message id, MAC, uptime). A group bot
# in privacy mode sees only replies to its own messages, so the prompt is a force_reply (D87).
# Nothing but the final name touches flash (R34c). The names are one file, $NT_NM_FILE, "<mac>
# <TAB> <name>" per line, newest last; it is written atomically and only when it changes (R50a, D88).

NT_NM_FILE=$NT_DIR/devnames
NT_NM_PICK=$NT_RUN/name_pick
NT_NM_ASKS=$NT_RUN/name_asks
# R50, R50a, D89: characters of a name, entries on flash, devices in the list, open prompts in RAM
NT_NM_LEN=24
NT_NM_MAX=64
NT_NM_SHOWN=12
NT_NM_ASKS_MAX=16
# Seconds a list of devices and a prompt stay valid (uptime clock, like the restart question)
NT_NM_TTL=${LW_NOTIFY_NAME_TTL:-600}
# The start of the prompt; a reply to a message that begins so is a name, whatever our memory says
NT_NM_HEAD='✏️ Send the new name for'
NT_NM_GONE='This request expired, tap ✏️ Name a device again.'

# nt_nm_markup: the button under the /devices list, as a reply_markup field.
nt_nm_markup() {
    nt_markup '{"inline_keyboard":[[{"text":"✏️ Name a device","callback_data":"dn:new"}]]}'
}

# nt_nm_get MAC: the name of MAC from the file; fails when there is none.
nt_nm_get() {
    awk -F'\t' -v m="$1" '$1 == m && $2 != "" { print $2; f = 1; exit } END { exit !f }' \
        "$NT_NM_FILE" 2>/dev/null
}

# nt_nm_lines: the names as "N <mac> <name>" lines, the form nt_devices_list takes after the DHCP
# names, which they replace there (R50).
nt_nm_lines() {
    awk -F'\t' 'length($1) == 17 && $2 != "" { print "N", $1, $2 }' "$NT_NM_FILE" 2>/dev/null || :
}

# nt_nm_label MAC: what /devices calls the device, as plain text: the name from the file, else the
# DHCP name, else "Unknown device (…xx:yy)" (R44b, R50).
nt_nm_label() {
    nt_nm_get "$1" && return 0
    awk -v m="$1" '$1 == m && $2 != "" { print $2; f = 1; exit } END { exit !f }' \
        "$NT_NAMES" 2>/dev/null && return 0
    printf 'Unknown device (…%s)\n' "${1#??:??:??:??:}"
}

# nt_nm_clean TEXT MAX: TEXT as a name: control characters and line breaks gone (C0, DEL and the C1
# range U+0080 to U+009F), runs of spaces one space, no space at either end, at most MAX characters
# of UTF-8 (counted by lead bytes, so a cut never splits a multibyte character). Done over the bytes
# of a hexdump: busybox awk and ash count bytes. About 400 bytes are read, so a long message costs
# little; past the 400th byte only the continuation bytes of the character in progress are taken,
# so this cut does not split a character either. The result is printed through printf, which turns
# the octal escapes the awk prints into bytes (the same way nt_urlencode "raw" does).
nt_nm_clean() {
    _nce=$(printf '%s' "$1" | head -c 403 | hexdump -v -e '/1 "%02X\n"' | awk -v max="$2" '
        BEGIN { for (i = 0; i < 256; i++) v[sprintf("%02X", i)] = i }
        function esc(c) { return sprintf("\\%03o", c) }
        function flush() {
            if (cur != "" && !ctl) { m++; ch[m] = cur; sp[m] = (cur == esc(32)) }
            cur = ""; ctl = 0
        }
        NR > 400 && (v[$1] < 128 || v[$1] >= 192) { exit }
        { b[++n] = v[$1] }
        END {
            for (i = 1; i <= n; i++) {
                c = b[i]
                if (c >= 128 && c < 192) {
                    if (cur != "") {
                        cur = cur esc(c)
                        if (lead == 194 && c < 160) ctl = 1
                    }
                    continue
                }
                flush()
                lead = c
                if (c < 32 || c == 127) continue
                cur = esc(c)
            }
            flush()
            for (i = 1; i <= m; i++) {
                if (sp[i] && (k == 0 || sp[k])) continue
                k++; out[k] = ch[i]; sp[k] = sp[i]
            }
            if (k > max) k = max
            while (k > 0 && sp[k]) k--
            for (i = 1; i <= k; i++) printf "%s", out[i]
        }')
    # shellcheck disable=SC2059  # the escapes are the format
    printf "$_nce"
}

# nt_nm_json TEXT: TEXT for a JSON string (a name can hold a quote or a backslash).
nt_nm_json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# nt_nm_set MAC NAME: the name into the file (NAME empty: out of it). The newest entry is the last
# line and a name that is already there is not written again; beyond NT_NM_MAX entries the oldest go.
# Returns 0 when the file changed, 1 when it did not need to, 2 when it could not be written.
nt_nm_set() {
    _nso=$(nt_nm_get "$1") || _nso=
    [ "$_nso" != "$2" ] || return 1
    _nsl=$(awk -F'\t' -v m="$1" 'NF >= 2 && $1 != m' "$NT_NM_FILE" 2>/dev/null)
    [ -z "$2" ] || _nsl=$(printf '%s\n%s\t%s\n' "$_nsl" "$1" "$2" | awk 'NF')
    _nsl=$(printf '%s\n' "$_nsl" | tail -n "$NT_NM_MAX")
    if [ -z "$_nsl" ]; then
        rm -f "$NT_NM_FILE"
        return 0
    fi
    mkdir -p "$NT_DIR"
    printf '%s\n' "$_nsl" | lw_write_atomic "$NT_NM_FILE" && return 0
    rm -f "$NT_NM_FILE.tmp.$$"
    return 2
}

# nt_nm_asks_live: the open prompts that have not run out, as "<message id> <mac> <uptime>" lines.
nt_nm_asks_live() {
    awk -v now="$(nt_now)" -v ttl="$NT_NM_TTL" '$3 + ttl > now' "$NT_NM_ASKS" 2>/dev/null
}

# nt_nm_ask_add MSGID MAC: remember a prompt; the oldest beyond NT_NM_ASKS_MAX are forgotten.
nt_nm_ask_add() {
    {
        nt_nm_asks_live
        printf '%s %s %s\n' "$1" "$2" "$(nt_now)"
    } | tail -n "$NT_NM_ASKS_MAX" >"$NT_NM_ASKS.new" && mv -f "$NT_NM_ASKS.new" "$NT_NM_ASKS"
}

# nt_nm_ask_mac MSGID: the MAC the live prompt MSGID is for; fails when there is none.
nt_nm_ask_mac() {
    nt_nm_asks_live | awk -v id="$1" '$1 == id { print $2; f = 1; exit } END { exit !f }'
}

# nt_nm_ask_drop MSGID: the prompt is done.
nt_nm_ask_drop() {
    nt_nm_asks_live | awk -v id="$1" '$1 != id' >"$NT_NM_ASKS.new"
    mv -f "$NT_NM_ASKS.new" "$NT_NM_ASKS"
}

# nt_nm_pick_load: the open list of devices into NT_NM_PMSG and NT_NM_PAT; fails when there is none
# or it has run out. The MACs it offered are the lines from the third on.
nt_nm_pick_load() {
    [ -f "$NT_NM_PICK" ] || return 1
    {
        read -r NT_NM_PMSG
        read -r NT_NM_PAT
    } <"$NT_NM_PICK"
    case $NT_NM_PMSG$NT_NM_PAT in '' | *[!0-9]*) return 1 ;; esac
    [ $(($(nt_now) - NT_NM_PAT)) -lt "$NT_NM_TTL" ]
}

# nt_nm_pick_close TEXT: the open list ends: forget it and show TEXT in its message, without buttons.
nt_nm_pick_close() {
    rm -f "$NT_NM_PICK"
    nt_edit "$NT_NM_PMSG" "$1" "$NT_NOKB" || :
}

# nt_nm_row_end: the row being built goes into the keyboard.
nt_nm_row_end() {
    [ "$_nmcnt" -gt 0 ] || return 0
    [ -z "$_nmj" ] || _nmj="$_nmj,"
    _nmj="${_nmj}[$_nmrow]"
    _nmrow=
    _nmcnt=0
}

# nt_nm_row_add LABEL BUTTON: a button, beside the one before it when both labels are short (R50,
# D89), else in a row of its own.
nt_nm_row_add() {
    if [ "$_nmcnt" = 1 ] && [ "$_nmshort" = 1 ] && [ "${#1}" -le 14 ]; then
        _nmrow="$_nmrow,$2"
        _nmcnt=2
        nt_nm_row_end
        return 0
    fi
    nt_nm_row_end
    _nmrow=$2
    _nmcnt=1
    _nmshort=0
    [ "${#1}" -gt 14 ] || _nmshort=1
}

# nt_nm_pick_markup: the keyboard of the list from the MACs in $NT_RUN/name_cand, and a Cancel.
nt_nm_pick_markup() {
    _nmj=
    _nmrow=
    _nmcnt=0
    _nmshort=0
    while read -r _nmm; do
        _nmlb=$(nt_nm_clean "$(nt_nm_label "$_nmm")" 28)
        _nmd=$(printf '%s' "$_nmm" | tr -d ':')
        nt_nm_row_add "$_nmlb" "{\"text\":\"$(nt_nm_json "$_nmlb")\",\"callback_data\":\"dn:$_nmd\"}"
    done <"$NT_RUN/name_cand"
    nt_nm_row_add Cancel '{"text":"Cancel","callback_data":"dn:no"}'
    nt_nm_row_end
    printf '{"inline_keyboard":[%s]}' "$_nmj"
}

# nt_nm_pick_cmd (R50): the list of devices of this month, those without a name first, then the rest
# as /devices lists them, at most NT_NM_SHOWN. The list is built the way /devices builds its own
# ("M <mac> n|u" lines of nt_devices_list: named or not).
nt_nm_pick_cmd() {
    if nt_nm_pick_load; then nt_nm_pick_close "✏️ Naming cancelled."; fi
    nt_devices_text >/dev/null
    sed -n 's/^M \([0-9a-f:]*\) \(.\)$/\1 \2/p' "$NT_RUN/dev_list" >"$NT_RUN/name_all"
    {
        sed -n 's/ u$//p' "$NT_RUN/name_all"
        sed -n 's/ n$//p' "$NT_RUN/name_all"
    } | head -n "$NT_NM_SHOWN" >"$NT_RUN/name_cand"
    rm -f "$NT_RUN/name_all"
    if [ ! -s "$NT_RUN/name_cand" ]; then
        rm -f "$NT_RUN/name_cand"
        nt_send "📱 No device to name yet: none was seen this month."
        return 0
    fi
    if nt_send "✏️ <b>Which device do you want to name?</b>" "$(nt_markup "$(nt_nm_pick_markup)")"; then
        case $NT_MSGID in
            '' | *[!0-9]*) ;;
            *) { printf '%s\n%s\n' "$NT_MSGID" "$(nt_now)"; cat "$NT_RUN/name_cand"; } >"$NT_NM_PICK" ;;
        esac
    fi
    rm -f "$NT_RUN/name_cand"
}

# nt_nm_expired: the pop-up of a button that is no longer good; nothing else happens.
nt_nm_expired() {
    nt_answer "$NT_CB" "&show_alert=true&text=$(nt_urlencode 'This button expired, tap ✏️ Name a device again.')"
}

# nt_nm_ask MAC: the prompt for the name of MAC, a force_reply (D87); the list in the chat becomes
# "Naming X" without buttons. A prompt that does not go out leaves the list as it is.
nt_nm_ask() {
    _nml=$(nt_nm_label "$1")
    _nmpl='{"force_reply":true,"input_field_placeholder":"New name, up to 24 characters"}'
    nt_send "$NT_NM_HEAD <b>$(nt_hd "$_nml")</b> as a reply to this message.
Up to $NT_NM_LEN characters. Send <code>-</code> to remove a name." "$(nt_markup "$_nmpl")" || return 0
    case $NT_MSGID in '' | *[!0-9]*) return 0 ;; esac
    nt_nm_ask_add "$NT_MSGID" "$1"
    nt_nm_pick_close "✏️ Naming <b>$(nt_hd "$_nml")</b>"
}

# nt_nm_tap (R50): a tap on a button "dn:..." : "new" under /devices opens the list; in the list
# "no" is Cancel and twelve hex digits are a device. A button of a list that is gone, was replaced or
# ran out gets the pop-up and changes nothing (like R45); a MAC the list did not offer is the same.
nt_nm_tap() {
    _nmt=${NT_CBDATA#dn:}
    if [ "$_nmt" = new ]; then
        nt_answer "$NT_CB"
        nt_nm_pick_cmd
        return 0
    fi
    if ! nt_nm_pick_load || [ "$NT_CBMSG" != "$NT_NM_PMSG" ]; then
        nt_nm_expired
        return 0
    fi
    case $_nmt in
        no)
            nt_answer "$NT_CB"
            nt_nm_pick_close "✏️ Naming cancelled."
            return 0
            ;;
        *[!0-9a-f]* | '') ;;
        ????????????)
            _nmm=$(printf '%s' "$_nmt" | sed 's/\(..\)/\1:/g; s/:$//')
            if tail -n +3 "$NT_NM_PICK" | grep -qx "$_nmm"; then
                nt_answer "$NT_CB"
                nt_nm_ask "$_nmm"
                return 0
            fi
            ;;
    esac
    nt_nm_expired
}

# nt_nm_apply MAC NAME: the reply of a prompt takes effect; NAME is cleaned. Answers in the chat.
# Returns 0 when the prompt is used up (a name, a removal, a name that was already there, nothing to
# remove) and 1 when it stays open for another try (an empty name, a flash that cannot be written).
nt_nm_apply() {
    nt_defuse "$(nt_nm_clean "$2" 400)"
    _nmn=$(nt_nm_clean "$NT_DEF" "$NT_NM_LEN")
    if [ -z "$_nmn" ]; then
        nt_send "⚠️ That name is empty. Reply to the message above with a name of up to $NT_NM_LEN characters." ||
            :
        return 1
    fi
    _nmo=$(nt_nm_label "$1")
    _nmc=$(nt_nm_get "$1") || _nmc=
    if [ "$_nmn" = - ]; then
        _nmn=
        if [ -z "$_nmc" ]; then
            nt_send "ℹ️ <b>$(nt_hd "$_nmo")</b> has no name of its own, nothing to remove." || :
            return 0
        fi
    fi
    _nmr=0
    nt_nm_set "$1" "$_nmn" || _nmr=$?
    if [ "$_nmr" = 2 ]; then
        nt_send "⚠️ Could not save the name (the router's flash is full or read-only)." || :
        return 1
    fi
    if [ -z "$_nmn" ]; then
        nt_send "✅ Name removed: <b>$(nt_hd "$_nmc")</b>." || :
    else
        nt_send "✅ <b>$(nt_hd "$_nmo")</b> is now called <b>$(nt_hd "$_nmn")</b>." || :
    fi
    return 0
}

# nt_nm_reply (R50): a message that is a reply (NT_RTO, the id of the message it answers; NT_RTXT, its
# text) to one of our prompts is a name. Whatever a reply to another message is, it is not ours:
# fails then, so the caller goes on with it as a command. A text that is a command or the label of a
# keyboard button is not a name either: the app may send a press while a reply is open. A reply to a
# prompt that ran out or that the router forgot (a restart) gets the "expired" line. Returns 0 when
# it dealt with the message.
nt_nm_reply() {
    case $NT_RTO in '' | *[!0-9]*) return 1 ;; esac
    case $NT_CMD in /*) return 1 ;; esac
    # the prompt test forks nothing, so a keyboard press (a reply to the greeting) costs no awk here
    nt_fe_strip "$NT_RTXT"
    _nmh=$NT_STRIP
    nt_fe_strip "$NT_NM_HEAD"
    case $_nmh in "$NT_STRIP"*) ;; *) return 1 ;; esac
    [ -z "$(nt_button_cmd "$NT_CMD")" ] || return 1
    if ! _nmm=$(nt_nm_ask_mac "$NT_RTO"); then
        nt_send "$NT_NM_GONE" || :
        return 0
    fi
    ! nt_nm_apply "$_nmm" "$NT_CMD" || nt_nm_ask_drop "$NT_RTO"
    return 0
}
