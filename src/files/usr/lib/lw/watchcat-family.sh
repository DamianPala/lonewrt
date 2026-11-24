# The family check of watchcat (SPEC R14, R14b, R14d, R14f, R14g, R77b, R77d, D195, D198, D200).
# Sourced by the image's /usr/bin/watchcat.sh, derived from the package (watchcat-handler.sh), only
# in the instance of the entry with the option lw_family_check, which is wwan_soft; another entry
# never loads this file. POSIX sh for busybox ash.
#
# The worker's loop over the hosts is emptied for this instance and lw_wc_round runs in its place,
# once per ping period, before the worker's own test of the silence timer. It reads and sets the
# worker's variables: time_now, time_lastcheck, time_lastcheck_withinternet (the silence timer is
# fed from here), failure_period, ping_size and iface. Everything after that stays stock: the wait
# after boot, the test of the timer, the restart of the interface, the timer reset, the repeat after
# every period.

# shellcheck disable=SC2154,SC2034  # the worker's variables (iface, failure_period, time_now, ...) are read and set here, and eval sets some
# shellcheck source=src/files/usr/lib/lw/common.sh
. /usr/lib/lw/common.sh
# shellcheck source=src/files/usr/lib/lw/probe.sh
. /usr/lib/lw/probe.sh

# R14f: the deadline (second of the uptime clock) of a start of wwan that is negotiating, written by
# the handler (qmi-edits/functions.sh) and removed when the negotiation ends; in the family directory
# of root (common.sh), and no later than this many seconds from now whatever the file says (R73h)
LW_WC_NEG=${LW_WC_NEG:-${LW_FAMILY_DIR:-/var/run/lw-family}/negotiating}
LW_WC_NEG_MAX=60
# R77d: the counters of the session's own device; a difference of this many packets since the
# previous check, both ways, other than the probes, is traffic that was answered
LW_WC_STATS=${LW_WC_STATS:-/sys/class/net}
LW_WC_TRAFFIC=${LW_WC_TRAFFIC:-4}
# R77b: checks in a row with no answer in one family while another answers
LW_WC_LOST_AFTER=3

# per family: checks in a row without an answer (_lw_wc_m4, _lw_wc_m6) and whether the loss has been
# logged (_lw_wc_l4, _lw_wc_l6); the counters of the device in the last check (R77d)
_lw_wc_m4=0 _lw_wc_m6=0 _lw_wc_l4=0 _lw_wc_l6=0
_lw_wc_rx='' _lw_wc_tx='' _lw_wc_dev=''

# lw_wc_say TEXT: one line in the tag and at the priority of watchcat's own lines
lw_wc_say() {
    logger -p daemon.info -t "watchcat[$$]" "$1"
}

# lw_wc_state: R77b, D200. A family of the session that has had no answer in 3 checks in a row while
# the other answered is a family lost: one line when it becomes one, one at its first answer after.
# It restarts nothing, and no failure follows: the silence timer is fed by any family.
lw_wc_state() {
    for _lw_wf in 4 6; do
        eval "_lw_wo=\$LW_P_OK$_lw_wf _lw_wm=\$_lw_wc_m$_lw_wf _lw_wl=\$_lw_wc_l$_lw_wf"
        # a family the session does not have, a check that no family answered, or both answered
        if [ -z "$_lw_wo" ] || [ "$LW_P_ONLINE" = 0 ]; then
            _lw_wm=0
            [ -n "$_lw_wo" ] || _lw_wl=0
        elif [ "$_lw_wo" = 1 ]; then
            _lw_wm=0
            if [ "$_lw_wl" = 1 ]; then
                lw_wc_say "IPv$_lw_wf answers again"
                _lw_wl=0
            fi
        else
            _lw_wm=$((_lw_wm + 1))
            if [ "$_lw_wm" -ge "$LW_WC_LOST_AFTER" ] && [ "$_lw_wl" = 0 ]; then
                lw_wc_say "IPv$_lw_wf did not answer in $LW_WC_LOST_AFTER checks in a row while the other version did; wwan is not restarted for it"
                _lw_wl=1
            fi
        fi
        eval "_lw_wc_m$_lw_wf=\$_lw_wm _lw_wc_l$_lw_wf=\$_lw_wl"
    done
}

# lw_wc_traffic: R77d, D198. In a session without native IPv4 (IPv6 alone, with or without the
# translation), IPv6 traffic of the session's own device that answered a connection from inside since
# the previous check counts as online for that check, so a path that carries TCP but drops the
# probes does not look dead. The measure is the packet counters of the device: at least
# LW_WC_TRAFFIC packets received and as many sent, the probes of this check taken off the sent ones
# (an answered probe would have made the check online anyway). Four file reads, no fork. Exit 0 when
# there was such traffic; the counters are read at every check, so the next one has its baseline.
lw_wc_traffic() {
    _lw_wt=1
    if [ "$LW_P_HAS6" != 1 ] || [ -z "$LW_P_DEV6" ] || { [ "$LW_P_HAS4" = 1 ] && [ "$LW_P_XLAT" = 0 ]; }; then
        _lw_wc_dev=''
        return 1
    fi
    _lw_wd=$LW_WC_STATS/$LW_P_DEV6/statistics
    if ! { read -r _lw_wx <"$_lw_wd/rx_packets" && read -r _lw_wy <"$_lw_wd/tx_packets"; } 2>/dev/null; then
        _lw_wc_dev=''
        return 1
    fi
    case $_lw_wx$_lw_wy in '' | *[!0-9]*)
        _lw_wc_dev=''
        return 1
        ;;
    esac
    if [ "$_lw_wc_dev" = "$LW_P_DEV6" ]; then
        _lw_wi=$((_lw_wx - _lw_wc_rx))
        _lw_wo=$((_lw_wy - _lw_wc_tx - LW_P_N6))
        if [ "$_lw_wi" -ge "$LW_WC_TRAFFIC" ] && [ "$_lw_wo" -ge "$LW_WC_TRAFFIC" ]; then
            _lw_wt=0
        fi
    fi
    _lw_wc_dev=$LW_P_DEV6 _lw_wc_rx=$_lw_wx _lw_wc_tx=$_lw_wy
    return "$_lw_wt"
}

# lw_wc_unreached: the stock line of watchcat for an address that did not answer, only while the
# whole check is silent (the silence timer is counting), and only for the families of the session
lw_wc_unreached() {
    for _lw_wf in 4 6; do
        eval "_lw_wo=\$LW_P_OK$_lw_wf _lw_wh=\$LW_P_HOSTS$_lw_wf"
        [ "$_lw_wo" = 0 ] || continue
        for _lw_wa in $_lw_wh; do
            lw_wc_say "Could not reach $_lw_wa via \"$iface\" for \"$((time_now - time_lastcheck_withinternet))\" seconds. Will restart \"$iface\" after \"$failure_period\" seconds of failed reachability"
        done
    done
}

# lw_wc_check: one scheduled family check (R14): the result feeds the silence timer, the IPv6 result
# goes to the session watcher (R14g), and the state of each family is kept (R77b).
lw_wc_check() {
    LW_P_WSIZE=${ping_size:-56}
    lw_probe_round watchcat || :
    lw_probe_publish_v6
    lw_wc_state
    _lw_wk=0
    if lw_wc_traffic; then _lw_wk=1; fi
    if [ "$LW_P_ONLINE" = 1 ]; then
        time_lastcheck_withinternet="$time_now"
    elif [ "$_lw_wk" = 1 ]; then
        lw_debug watchcat "no answer from the probes, but IPv6 traffic of $LW_P_DEV6 was answered since the last check"
        time_lastcheck_withinternet="$time_now"
    else
        lw_wc_unreached
    fi
}

# lw_wc_wait: R14f, D197. The silence timer has run out while a start of wwan is within its
# negotiation deadline: the restart would cut that start, so wait for it, up to a guard that ends
# with the deadline, then look once more; a link that is up by then feeds the timer, and a start that
# hangs to its deadline is restarted as R14 says, once.
lw_wc_wait() {
    lw_state_dir_ok "${LW_WC_NEG%/*}" || return 0
    [ -f "$LW_WC_NEG" ] || return 0
    [ "$((time_now - time_lastcheck_withinternet))" -ge "$failure_period" ] || return 0
    read -r _lw_wd <"$LW_WC_NEG" || :
    case $_lw_wd in '' | *[!0-9]*) return 0 ;; esac
    _lw_pnow
    # a mark never holds watchcat back longer than a negotiation lasts (R14f, R73h); a number too long
    # for the shell's arithmetic is as far away as any other
    _lw_wmax=$((_lw_pn + LW_WC_NEG_MAX))
    if [ "${#_lw_wd}" -gt 9 ] || [ "$_lw_wd" -gt "$_lw_wmax" ]; then _lw_wd=$_lw_wmax; fi
    [ "$_lw_pn" -lt "$_lw_wd" ] || return 0
    lw_debug watchcat "the silence timer ran out during a start of wwan, waiting for it until second $_lw_wd"
    while [ -f "$LW_WC_NEG" ]; do
        _lw_pnow
        [ "$_lw_pn" -lt "$_lw_wd" ] || break
        sleep 1
    done
    time_now=$_lw_pn
    time_lastcheck=$_lw_pn
    LW_P_WSIZE=${ping_size:-56}
    if lw_probe_round watchcat; then
        time_lastcheck_withinternet="$time_now"
    fi
}

# lw_wc_round: what the worker runs in place of its loop over the hosts
lw_wc_round() {
    lw_wc_check
    lw_wc_wait
}
