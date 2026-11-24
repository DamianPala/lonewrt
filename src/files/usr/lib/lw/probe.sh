# The image's family-aware link checks: which IP families the LTE session has, and whether the
# internet answers through its own devices (SPEC Terms "session", "cellular answer" and "online",
# R77 to R77c, R18c, R28, D173, D185). Sourced, never executed. POSIX sh for busybox ash.
#
#   lw_probe_session   read the session from netifd. LW_P_HAS4 and LW_P_HAS6 say which families it
#                      has (1/0), LW_P_DEV4 and LW_P_DEV6 the device each can be probed on now (empty
#                      = not ready), LW_P_XLAT 1 when the IPv4 goes over the translation
#   lw_probe_round [recover|notify|watchcat]   one round of pings with the parameters of that
#                      consumer (see _lw_pfam; Terms "online"): LW_P_OK4 and LW_P_OK6 (1, 0, or empty
#                      for a family the session does not have), LW_P_ONLINE (1 or 0), LW_P_MS (the
#                      round trip in ms of the first answer, IPv4 before IPv6), LW_P_T6 (the second on
#                      the uptime clock at which the IPv6 pings began), LW_P_N6 (IPv6 pings run); exit
#                      0 when online
#   lw_probe_publish_v6   R14g, D204: after a round of the profile watchcat, the IPv6 result for the
#                      session watcher; no other consumer calls it
#   lw_probe_dns       LW_P_DNS: the operator DNS of the session; exit 1 when it has none
#   lw_probe_dns_path  exit 0 when the route to LW_P_DNS leaves on the cellular device of its family
#   lw_probe_stats FAMILY DEVICE   three pings for the signal log: LW_P_LOSS, LW_P_RTT
#
# Which families the session has comes from the call data the parent wwan publishes (data.cid_4 with
# data.pdh_4, data.cid_6 with data.pdh_6, Terms "session"), and a translation interface wwan_6_4
# gives IPv4 service to an IPv6 session. The devices only decide whether a family can be probed now:
# a family of the session without a ready device failed this round, it is never absent. Every ping is
# bound to the device of its own family with -4 or -6 and -I, so a reply that came over the tunnel,
# Tailscale or another interface is none. A parent with no call data falls back to the legacy IPv4
# probe on wwan0. Partial data is read the same way, with one debug line.

# shellcheck disable=SC2034  # the LW_P_* results are read by the scripts that source this file

# the two legacy IPv4 addresses and their IPv6 counterparts, the same two public DNS services (R77)
LW_P_HOSTS4=${LW_P_HOSTS4:-'8.8.8.8 1.1.1.1'}
LW_P_HOSTS6=${LW_P_HOSTS6:-'2001:4860:4860::8888 2606:4700:4700::1111'}
# the address of the signal log's ping (R28)
LW_P_STAT4=${LW_P_STAT4:-1.1.1.1}
LW_P_STAT6=${LW_P_STAT6:-2606:4700:4700::1111}
# the hard limit of one ping of the notify profile, as lw-notify had it (tests shorten it)
LW_P_NOTIFY_LIMIT=${LW_P_NOTIFY_LIMIT:-5}
# the watchcat profile (R14, R14d): the packet size of the entry (watchcat's own ping_size), the
# longest a ping waits (busybox ping without -W waits 10 s, as stock watchcat's ping does), and the
# bound of a whole round, device lookups included. The limit is 40 s, 37 here: the clock counts whole
# seconds (a round can start up to 1 s into one) and a killed ping gets 1 s of grace.
LW_P_WSIZE=${LW_P_WSIZE:-56}
LW_P_WWAIT=10
LW_P_WBOUND=${LW_P_WBOUND:-37}
# R14g: the file the session watcher reads; the writer makes its directory (0700, root's, common.sh)
# when it is missing
LW_P_V6_FILE=${LW_P_V6_FILE:-${LW_FAMILY_DIR:-/var/run/lw-family}/ipv6}

# _lw_pnow: the whole second of the uptime clock of common.sh in _lw_pn, with shell builtins only
_lw_pnow() {
    read -r _lw_pn _ <"$LW_UPTIME_FILE" || _lw_pn=0
    _lw_pn=${_lw_pn%%.*}
}

# _lw_pj JSON PATH: one value of a netifd reply, empty when there is none.
_lw_pj() {
    printf '%s\n' "$1" | jsonfilter -e "$2" 2>/dev/null | head -n 1
}

# _lw_pdev JSON: the modem device of a native family in a possibly partial netifd reply.
_lw_pdev() {
    _lw_pd=$(_lw_pj "$1" '@.l3_device')
    [ -n "$_lw_pd" ] || _lw_pd=$(_lw_pj "$1" '@.device')
    printf '%s\n' "${_lw_pd:-wwan0}"
}

# R77c: four lookups may cost at most 8 s even if netifd stalls, leaving time for all four pings.
_lw_pstatus() {
    timeout -k 1 1 ifstatus "$1" 2>/dev/null
}

# lw_probe_session (R77c): a fresh read at every call, so a new start or a translation that comes or
# goes is followed at the next round. The native IPv4 is the child wwan_4 (Terms), the translation
# wwan_6_4 (R76d, D191); the IPv6 is an address on the child wwan_6 or on wwan itself.
lw_probe_session() {
    LW_P_HAS4=0 LW_P_HAS6=0 LW_P_DEV4='' LW_P_DEV6='' LW_P_XLAT=0
    _lw_sw=$(_lw_pstatus wwan) || _lw_sw=''
    # the second of this read: the birth of the session is measured on it (R14g)
    _lw_pnow
    LW_P_READ=$_lw_pn
    _lw_s4=$(_lw_pstatus wwan_4) || _lw_s4=''
    _lw_s6=$(_lw_pstatus wwan_6) || _lw_s6=''
    _lw_sx=$(_lw_pstatus wwan_6_4) || _lw_sx=''
    _lw_bad=0
    _lw_pcall 4 || _lw_bad=1
    _lw_pcall 6 || _lw_bad=1
    if [ "$_lw_bad" = 1 ]; then
        lw_debug lw-probe "call data of wwan incomplete, read as IPv4 on wwan0"
        LW_P_HAS4=0 LW_P_HAS6=0
    fi
    if [ "$LW_P_HAS6" = 0 ]; then
        # R77a, R28: the IPv4-only probe always used the modem, including while DHCP was pending.
        LW_P_HAS4=1 LW_P_DEV4=wwan0
        return 0
    fi
    if [ "$LW_P_HAS4" = 1 ]; then
        if [ "$(_lw_pj "$_lw_s4" '@.up')" = true ]; then
            LW_P_DEV4=$(_lw_pdev "$_lw_s4")
        elif [ "$(_lw_pj "$_lw_sw" '@.up')" = true ] &&
            [ -n "$(_lw_pj "$_lw_sw" '@["ipv4-address"][0].address')" ]; then
            # R73p: QMI can publish static IPv4 on the parent without a DHCP child.
            LW_P_DEV4=$(_lw_pdev "$_lw_sw")
        fi
    elif [ -n "$_lw_sx" ]; then
        # R76d: the translation has a device of its own, never the modem's
        LW_P_HAS4=1 LW_P_XLAT=1
        if [ "$(_lw_pj "$_lw_sx" '@.up')" = true ]; then
            LW_P_DEV4=$(_lw_pj "$_lw_sx" '@.l3_device')
            LW_P_DEV4=${LW_P_DEV4:-464-wwan_6_4}
        fi
    fi
    for _lw_sj in "$_lw_s6" "$_lw_sw"; do
        [ "$(_lw_pj "$_lw_sj" '@.up')" = true ] || continue
        [ -n "$(_lw_pj "$_lw_sj" '@["ipv6-address"][0].address')" ] || continue
        LW_P_DEV6=$(_lw_pdev "$_lw_sj")
        break
    done
}

# _lw_pcall FAMILY: LW_P_HAS<family> from the published call (client and handle), exit 1 when only
# one of the two is there.
_lw_pcall() {
    _lw_cc=$(_lw_pj "$_lw_sw" "@.data.cid_$1")
    _lw_ch=$(_lw_pj "$_lw_sw" "@.data.pdh_$1")
    if [ -n "$_lw_cc" ] && [ -n "$_lw_ch" ]; then
        case $1 in 4) LW_P_HAS4=1 ;; *) LW_P_HAS6=1 ;; esac
    elif [ -n "$_lw_cc" ] || [ -n "$_lw_ch" ]; then
        return 1
    fi
    return 0
}

# _lw_pfam PROFILE FAMILY DEVICE HOSTS: the family's addresses in turn until one answers. Every
# consumer keeps the ping parameters it always had, for both families (R14, R77):
#   recover  (wwan-recover) ping -I DEV -c 2 -w 3 -q, no outer limit, any reply counts: with -w the
#            exit code also reports fewer replies than -c asked for, so the statistics line decides
#   notify   (lw-notify, and so smsctl.sh and speedtest.sh) timeout 5 ping -c 2 -w 3 -I DEV, answered
#            when ping exits 0
#   watchcat (watchcat's hook, R14, R14d) ping -4|-6 -I DEV -s SIZE -c 1, as stock watchcat pings, with
#            no wait option; answered when ping exits 0. Each ping gets the time left of the round's
#            bound (at most its own 10 s), none when less than a second is left.
# Sets _lw_pms to the round trip of the answer.
_lw_pfam() {
    _lw_pms=''
    for _lw_ph in $4; do
        [ "$2" != 6 ] || LW_P_N6=$((LW_P_N6 + 1))
        case $1 in
            watchcat)
                _lw_pnow
                _lw_pl=$((_lw_pend - _lw_pn))
                [ "$_lw_pl" -ge 1 ] || return 1
                [ "$_lw_pl" -le "$LW_P_WWAIT" ] || _lw_pl=$LW_P_WWAIT
                _lw_po=$(timeout -k 1 "$_lw_pl" ping "-$2" -I "$3" -s "$LW_P_WSIZE" -c 1 "$_lw_ph" 2>/dev/null) ||
                    continue
                ;;
            notify)
                _lw_po=$(timeout "$LW_P_NOTIFY_LIMIT" ping "-$2" -c 2 -w 3 -I "$3" "$_lw_ph" 2>/dev/null) ||
                    continue
                ;;
            *)
                _lw_po=$(ping "-$2" -I "$3" -c 2 -w 3 -q "$_lw_ph" 2>/dev/null) || :
                printf '%s\n' "$_lw_po" | grep -q ' [1-9][0-9]* packets received' || continue
                ;;
        esac
        _lw_pms=$(printf '%s\n' "$_lw_po" | sed -n 's|^.* = [0-9.]*/\([0-9.]*\)/.*|\1|p' | head -n 1)
        return 0
    done
    return 1
}

# lw_probe_round [PROFILE]: R77, R77a, R77c. Only the families the session has are pinged, so an
# IPv4-only session sees no IPv6 address, and one without IPv4 service no IPv4 address. A family of
# the session whose device is not ready has failed this round and is not pinged.
lw_probe_round() {
    _lw_pp=${1:-recover}
    # R14d: the bound counts from before the device lookups
    _lw_pnow
    _lw_pend=$((_lw_pn + LW_P_WBOUND))
    lw_probe_session
    LW_P_OK4='' LW_P_OK6='' LW_P_ONLINE=0 LW_P_MS='' LW_P_T6='' LW_P_N6=0
    _lw_m4='' _lw_m6=''
    if [ "$LW_P_HAS4" = 1 ]; then
        LW_P_OK4=0
        if [ -n "$LW_P_DEV4" ] && _lw_pfam "$_lw_pp" 4 "$LW_P_DEV4" "$LW_P_HOSTS4"; then
            LW_P_OK4=1 _lw_m4=$_lw_pms
        fi
    fi
    if [ "$LW_P_HAS6" = 1 ]; then
        LW_P_OK6=0
        _lw_pnow
        LW_P_T6=$_lw_pn
        if [ -n "$LW_P_DEV6" ] && _lw_pfam "$_lw_pp" 6 "$LW_P_DEV6" "$LW_P_HOSTS6"; then
            LW_P_OK6=1 _lw_m6=$_lw_pms
        fi
    fi
    LW_P_MS=${_lw_m4:-$_lw_m6}
    if [ "$LW_P_OK4" = 1 ] || [ "$LW_P_OK6" = 1 ]; then LW_P_ONLINE=1; fi
    [ "$LW_P_ONLINE" = 1 ]
}

# lw_probe_dns: R18c, Terms "operator DNS". LW_P_DNS is the DNS server of the native IPv4 lease,
# else one of the session's IPv6 settings (the child wwan_6, or wwan itself); a session without a
# server has none (exit 1).
lw_probe_dns() {
    lw_probe_session
    LW_P_DNS=$(_lw_pj "$_lw_s4" '@["dns-server"][0]')
    if [ -z "$LW_P_DNS" ] && [ "$LW_P_HAS6" = 1 ]; then
        for _lw_sj in "$_lw_s6" "$_lw_sw"; do
            LW_P_DNS=$(_lw_pj "$_lw_sj" '@["dns-server"][0]')
            [ -z "$LW_P_DNS" ] || break
        done
    fi
    [ -n "$LW_P_DNS" ]
}

# lw_probe_dns_path (R18c): an answer of LW_P_DNS is evidence about the account only when the route to
# that server leaves on the cellular device of its family, so a server that a tunnel, the LAN or
# another WAN also reaches proves nothing. No device, no route or another device is no evidence (exit
# 1, one debug line); the caller goes on as for a silent server.
lw_probe_dns_path() {
    case $LW_P_DNS in *:*) _lw_wf=6 _lw_wd=$LW_P_DEV6 ;; *) _lw_wf=4 _lw_wd=$LW_P_DEV4 ;; esac
    _lw_rd=''
    # R18c: a stalled or failed routing lookup carries no evidence about the account.
    if _lw_route=$(timeout -k 1 1 ip "-$_lw_wf" route get "$LW_P_DNS" 2>/dev/null); then
        _lw_rd=$(printf '%s\n' "$_lw_route" | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1)
    fi
    [ -n "$_lw_wd" ] && [ "$_lw_rd" = "$_lw_wd" ] && return 0
    lw_debug lw-probe "operator DNS $LW_P_DNS: route leaves on '${_lw_rd:-none}', the session's device is '${_lw_wd:-none}', no evidence"
    return 1
}

# lw_probe_stats FAMILY DEVICE (R28): the signal log's ping, 3 packets with a 2 s wait, to one
# address of the family through the session's device. LW_P_LOSS is "N%" and LW_P_RTT the average
# in ms, each empty without a reading. A family without a ready device (empty DEVICE) lost everything.
lw_probe_stats() {
    LW_P_LOSS=100% LW_P_RTT=''
    [ -n "$2" ] || return 0
    case $1 in 6) _lw_ph=$LW_P_STAT6 ;; *) _lw_ph=$LW_P_STAT4 ;; esac
    _lw_po=$(timeout 15 ping "-$1" -c 3 -W 2 -I "$2" "$_lw_ph" 2>/dev/null) || :
    LW_P_LOSS=$(printf '%s\n' "$_lw_po" | sed -n 's/.* \([0-9]*%\) packet loss.*/\1/p')
    LW_P_RTT=$(printf '%s\n' "$_lw_po" | sed -n 's|.*= [0-9.]*/\([0-9.]*\)/.*|\1|p')
}

# lw_probe_publish_v6 (R14g, D204): the IPv6 result of the round just run with the profile watchcat,
# for the session watcher (lk_v6_silent in lw-linkwatch reads it). Only watchcat's hook calls it, and
# no other check may: a result of another check would be read as if it were watchcat's. The file is
# one line, `<cid_4>/<pdh_4> <birth> <second> <result>`, in a directory of mode 0700 made when it is
# missing, written beside the file and renamed over it. The call numbers and the birth come from the
# status read of that round (the birth is netifd's uptime of wwan taken from the uptime second of
# that read, not of this write, which comes up to 40 s later), `second` is the second the IPv6 pings
# began, and the result is answer, none (a ready device, no answer) or nodev (nothing pinged). A
# session without IPv6 or without an IPv4 call writes nothing, and removes nothing.
lw_probe_publish_v6() {
    [ "$LW_P_HAS6" = 1 ] || return 0
    _lw_wc=$(_lw_pj "$_lw_sw" '@.data.cid_4')
    _lw_wh=$(_lw_pj "$_lw_sw" '@.data.pdh_4')
    [ -n "$_lw_wc" ] && [ -n "$_lw_wh" ] || return 0
    case $_lw_wc$_lw_wh in *[!0-9-]*) return 0 ;; esac
    case $LW_P_T6 in '' | *[!0-9]*) return 0 ;; esac
    if [ -z "$LW_P_DEV6" ]; then
        _lw_wr=nodev
    elif [ "$LW_P_OK6" = 1 ]; then
        _lw_wr=answer
    else
        _lw_wr=none
    fi
    _lw_wb=-
    _lw_wu=$(_lw_pj "$_lw_sw" '@.uptime')
    case $_lw_wu in '' | *[!0-9]*) ;; *)
        [ "$LW_P_READ" -lt "$_lw_wu" ] || _lw_wb=$((LW_P_READ - _lw_wu))
        ;;
    esac
    _lw_wd=${LW_P_V6_FILE%/*}
    # restart decisions read the file: a directory that is not root's, or a link, gets nothing
    if ! { (umask 077 && mkdir -p "$_lw_wd") && lw_state_dir_ok "$_lw_wd" && chmod 0700 "$_lw_wd"; } 2>/dev/null; then
        lw_debug lw-probe "$_lw_wd is not a directory of root, the IPv6 result is not written"
        return 0
    fi
    if printf '%s/%s %s %s %s\n' "$_lw_wc" "$_lw_wh" "$_lw_wb" "$LW_P_T6" "$_lw_wr" \
        >"$_lw_wd/.ipv6.$$" 2>/dev/null &&
        mv -f "$_lw_wd/.ipv6.$$" "$LW_P_V6_FILE" 2>/dev/null; then
        return 0
    fi
    rm -f "$_lw_wd/.ipv6.$$"
    lw_debug lw-probe "the IPv6 result is not written to $LW_P_V6_FILE"
}
