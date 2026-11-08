# Restart of the router from the chat, confirmed with a button (SPEC R45, R45a, D60): the code
# behind /reboot. Sourced by /usr/sbin/lw-notify after notify.sh. POSIX sh for busybox ash; every
# name has the nt_rb_ prefix.
#
# /reboot sends a question with two buttons and remembers it in $NT_RUN (RAM) as three lines: a
# nonce that only this question's buttons carry, the id of the message and the uptime of the ask.
# The restart happens only on a tap of "Restart" with that nonce, inside NT_RB_TTL seconds, from the
# configured chat. nt_rb_go below is the only place in the notification code that restarts the
# router (R37a); the SMS command REBOOT of smsctl.sh (R46b) calls it too.
#
# Before the restart one record goes to flash ($NT_RB: name, time, boot id, channel); the first pass
# after the boot sends "Router back" and deletes it (R45a, R46b). A restart nobody asked for has no
# record.
# shellcheck disable=SC2153  # NT_* are set by notify.sh and /usr/sbin/lw-notify

# nt_rb_get KEY: a value of the record on flash.
nt_rb_get() { sed -n "s/^$1=//p" "$NT_RB" 2>/dev/null | head -n 1; }

nt_boot_id() { head -n 1 "$NT_BOOT_ID" 2>/dev/null; }

# nt_rb_pending: the record on flash belongs to a restart that really happened (another boot).
nt_rb_pending() {
    [ -f "$NT_RB" ] && [ "$(nt_rb_get boot)" != "$(nt_boot_id)" ]
}

# nt_rb_load: the open question into NT_RB_NONCE, NT_RB_MSG, NT_RB_AT; fails when there is none.
nt_rb_load() {
    [ -f "$NT_RUN/reboot_req" ] || return 1
    {
        read -r NT_RB_NONCE
        read -r NT_RB_MSG
        read -r NT_RB_AT
    } <"$NT_RUN/reboot_req"
    case $NT_RB_AT in '' | *[!0-9]*) return 1 ;; esac
    [ -n "$NT_RB_NONCE" ]
}

# nt_rb_age: seconds since the question was asked.
nt_rb_age() { echo $(($(nt_now) - NT_RB_AT)); }

# nt_rb_close TEXT: the question is over: forget it and show TEXT in its message, without buttons.
nt_rb_close() {
    rm -f "$NT_RUN/reboot_req"
    [ -z "$NT_RB_MSG" ] || nt_edit "$NT_RB_MSG" "$1" "$NT_NOKB" || :
}

# nt_rb_expire: the open question, if any, ends as "not confirmed" (the time is up, a newer question
# replaces it, or the service started again).
nt_rb_expire() {
    ! nt_rb_load || nt_rb_close "Restart not confirmed, nothing done."
}

# nt_reboot_cmd (R45): ask, with two buttons.
nt_reboot_cmd() {
    nt_rb_expire
    _rn=$(head -c 4 /dev/urandom | hexdump -v -e '/1 "%02x"')
    _rj='{"inline_keyboard":[[{"text":"🔄 Restart","callback_data":"rb:'$_rn':go"},'
    _rj=$_rj'{"text":"Cancel","callback_data":"rb:'$_rn':no"}]]}'
    nt_send "⚠️ Restart the router?
Internet and Wi-Fi go down for about 2 min." "$(nt_markup "$_rj")" || return 0
    printf '%s\n%s\n%s\n' "$_rn" "$NT_MSGID" "$(nt_now)" >"$NT_RUN/reboot_req"
}

# nt_rb_tick: every pass; the question that nobody answered ends after NT_RB_TTL s (R45).
nt_rb_tick() {
    nt_rb_load || return 0
    [ "$(nt_rb_age)" -lt "$NT_RB_TTL" ] || nt_rb_close "Restart not confirmed, nothing done."
}

# nt_rb_wait_cap WAIT: WAIT, or less when the open question ends sooner, so the loop does not sleep
# through its end.
nt_rb_wait_cap() {
    if nt_rb_load; then
        _rr=$((NT_RB_TTL - $(nt_rb_age)))
        [ "$_rr" -ge 1 ] || _rr=1
        [ "$1" -le "$_rr" ] || set -- "$_rr"
    fi
    echo "$1"
}

# nt_rb_name: who tapped, as one short line.
nt_rb_name() {
    _rm=$(nt_clean "$NT_CBNAME" | cut -c1-40)
    echo "${_rm:-someone}"
}

# nt_rb_record NAME [VIA]: the one write to flash before the restart (R45a). The wall time counts
# only when ntpd had synced the clock. VIA is "sms" for a restart by an SMS command (R46b), where
# NAME is the sender's number; the chat message names the channel.
nt_rb_record() {
    mkdir -p "$NT_DIR"
    _rk=0
    ! nt_clock_ok || _rk=1
    printf 'name=%s\nwall=%s\nntp=%s\nboot=%s\nup=%s\nvia=%s\n' "$1" "$(nt_wall)" "$_rk" \
        "$(nt_boot_id)" "$(lw_uptime)" "${2:-tg}" | lw_write_atomic "$NT_RB"
}

# nt_rb_go: the restart itself, the only one in the notification code (R37a). The data counters and
# the DHCP names go to flash first (R44a, R44b).
nt_rb_go() {
    nt_data_commit
    nt_names_save force
    sync
    reboot
}

# nt_reboot_tap (R45): a tap on a button of the question. A button of a question that is gone, was
# replaced or ran out gets the pop-up and changes nothing.
nt_reboot_tap() {
    _rt=${NT_CBDATA#rb:}
    _ra=${_rt##*:}
    _rt=${_rt%:*}
    if ! nt_rb_load || [ "$_rt" != "$NT_RB_NONCE" ] || [ "$(nt_rb_age)" -ge "$NT_RB_TTL" ]; then
        nt_answer "$NT_CB" "&show_alert=true&text=$(nt_urlencode 'This button expired, send /reboot again')"
        return 0
    fi
    _rw=$(nt_rb_name)
    case $_ra in
        go)
            rm -f "$NT_RUN/reboot_req"
            nt_answer "$NT_CB"
            nt_rb_record "$_rw"
            nt_edit "$NT_CBMSG" "🔄 Restarting now ($_rw tapped Restart)." "$NT_NOKB" || :
            nt_rb_go
            ;;
        no)
            nt_answer "$NT_CB"
            nt_rb_close "Restart cancelled."
            ;;
        *) nt_answer "$NT_CB" ;;
    esac
}

# nt_rb_span SECONDS: "50 s", "1 min 50 s", "5 min"; longer breaks as nt_span.
nt_rb_span() {
    if [ "$1" -ge 3600 ]; then
        nt_span "$1"
    else
        awk -v s="$1" 'BEGIN {
            if (s < 60) printf "%d s\n", s
            else if (s % 60) printf "%d min %d s\n", int(s / 60), s % 60
            else printf "%d min\n", s / 60 }'
    fi
}

# nt_rb_back_tick (R45a): the first pass with Telegram after the restart somebody asked for sends
# "Router back" once and deletes the record. It waits for ntpd, so the break can be measured; after
# NT_RB_WAIT s of uptime it goes out with an estimate and "~". The same boot id means the restart
# has not happened (yet): shutdown takes a few seconds, and a restart that failed leaves the record
# only until nt_rb_check_stale removes it.
nt_rb_back_tick() {
    nt_rb_pending || return 0
    nt_clock_ok || [ "$(lw_uptime)" -ge "$NT_RB_WAIT" ] || return 0
    _rw=$(nt_rb_get wall)
    _rd=$(($(lw_uptime) + NT_RB_GAP))
    _rl='~'
    case $_rw in '' | *[!0-9]*) _rw= ;; esac
    if [ -n "$_rw" ] && [ "$(nt_rb_get ntp)" = 1 ] && nt_clock_ok; then
        _rd=$(($(nt_wall) - _rw))
        _rl=
    fi
    [ "$_rd" -ge 0 ] || _rd=0
    _rc=0
    _rwho=$(nt_rb_get name)
    [ "$(nt_rb_get via)" != sms ] || _rwho="SMS from $_rwho"
    nt_send "🟢 Router back after restart (asked by $_rwho), down $_rl$(nt_rb_span "$_rd")." ||
        _rc=$?
    case $_rc in
        0 | 2) rm -f "$NT_RB" ;;
        *) return 1 ;;
    esac
}

# nt_rb_check_stale: a record of this very boot that is old: the restart never came (R45a).
nt_rb_check_stale() {
    [ -f "$NT_RB" ] && [ "$(nt_rb_get boot)" = "$(nt_boot_id)" ] || return 0
    _ru=$(nt_rb_get up)
    case $_ru in '' | *[!0-9]*) _ru=0 ;; esac
    [ $(($(lw_uptime) - _ru)) -ge 300 ] || return 0
    rm -f "$NT_RB"
}
