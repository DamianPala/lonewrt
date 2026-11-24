# The IPv6 traffic measure of the image's link checks (SPEC R77d, R14g, R49d, D198, D200). Sourced
# after probe.sh, never executed. POSIX sh for busybox ash.
#
#   lw_traffic_applies   exit 0 when the session just read by lw_probe_session has an IPv6 call with a
#                        ready device; a session without one reads no counters (IPv4 only: nothing
#                        here runs)
#   lw_traffic_measure DEVICE MAX_AGE [SAMPLE]
#                        one reading of the device's IPv6 counters against the SAMPLE the last check
#                        left. Sets LW_T_STATE to
#                          traffic  at least LW_TRAFFIC_MIN packets in and as many out since the sample
#                                   (exit 0)
#                          quiet    a valid sample and less than that (exit 1): the only evidence of
#                                   silence
#                          unknown  no sample, no counters, a counter that went back, a sample of
#                                   another device or session, or one older than MAX_AGE seconds
#                                   (exit 1)
#                        and LW_T_BASE to the reading just taken (empty when there is none), which the
#                        caller keeps for its next check: watchcat in memory, wwan-recover in its run
#                        file. MAX_AGE is two periods of the caller's check, so a missed check does not
#                        pass for a quiet one.
#
# The counters are the kernel's per-device IPv6 ones, /proc/net/dev_snmp6/<dev>: IPv6 in is the delta
# of Ip6InReceives less the delta of Icmp6InMsgs, IPv6 out the delta of Ip6OutTransmits less that of
# Icmp6OutMsgs. So router advertisements, neighbour discovery, MLD, the echo probes and every other
# ICMPv6 message of the router itself never count, and IPv4 is not in these counters at all; what is
# left is IPv6 data of the router and of the LAN through it (forwarded packets are in both counters).
# Busybox has no counter of TCP answers, so both ways beyond ICMPv6 is the approximation: a stream that
# is only retransmitted goes one way and stays quiet, and control traffic cannot reach the minimum.
#
# A sample belongs to a session and a device: the session is named as R14g names it, the call numbers
# of the IPv4 call (`cid_4/pdh_4`) or, without one, of the IPv6 call, and its birth (the second of the
# status read less netifd's uptime of wwan), which may differ by a few seconds from one read to the
# next. Reads: the counters file (no fork), the call data and uptime of the status read of the round
# (jsonfilter, as the writer of R14g does).

# shellcheck disable=SC2034,SC2154  # LW_T_* are read by the scripts that source this file; _lw_sw and _lw_pn come from probe.sh
LW_TRAFFIC_SNMP6=${LW_TRAFFIC_SNMP6:-/proc/net/dev_snmp6}
LW_TRAFFIC_MIN=${LW_TRAFFIC_MIN:-4}
# the births of one session read in two checks differ by the rounding of two whole seconds and the
# time a status read takes; the reader of R14g allows the same
LW_TRAFFIC_BIRTH_SLACK=6

lw_traffic_applies() {
    [ "$LW_P_HAS6" = 1 ] && [ -n "$LW_P_DEV6" ]
}

# _lw_tread DEVICE: the four counters in _lw_ta (Ip6InReceives), _lw_tb (Ip6OutTransmits), _lw_tc
# (Icmp6InMsgs) and _lw_td (Icmp6OutMsgs); exit 1 when the file or one of them is missing or not a
# number
_lw_tread() {
    _lw_ta='' _lw_tb='' _lw_tc='' _lw_td=''
    [ -r "$LW_TRAFFIC_SNMP6/$1" ] || return 1
    while read -r _lw_tk _lw_tv; do
        case $_lw_tk in
            Ip6InReceives) _lw_ta=$_lw_tv ;;
            Ip6OutTransmits) _lw_tb=$_lw_tv ;;
            Icmp6InMsgs) _lw_tc=$_lw_tv ;;
            Icmp6OutMsgs) _lw_td=$_lw_tv ;;
        esac
    done <"$LW_TRAFFIC_SNMP6/$1" 2>/dev/null
    for _lw_tv in "$_lw_ta" "$_lw_tb" "$_lw_tc" "$_lw_td"; do
        case $_lw_tv in '' | *[!0-9]*) return 1 ;; esac
    done
}

# _lw_tkey: the session of the status read of the last round, `<cid>/<pdh>` in _lw_tcalls and its
# birth (a second, or -) in _lw_tbirth; exit 1 when the call data are not complete
_lw_tkey() {
    _lw_tcc=$(_lw_pj "$_lw_sw" '@.data.cid_4')
    _lw_tch=$(_lw_pj "$_lw_sw" '@.data.pdh_4')
    if [ -z "$_lw_tcc" ] || [ -z "$_lw_tch" ]; then
        _lw_tcc=$(_lw_pj "$_lw_sw" '@.data.cid_6')
        _lw_tch=$(_lw_pj "$_lw_sw" '@.data.pdh_6')
    fi
    [ -n "$_lw_tcc" ] && [ -n "$_lw_tch" ] || return 1
    case $_lw_tcc$_lw_tch in *[!0-9-]*) return 1 ;; esac
    _lw_tcalls=$_lw_tcc/$_lw_tch
    _lw_tbirth=-
    _lw_tu=$(_lw_pj "$_lw_sw" '@.uptime')
    case $_lw_tu in '' | *[!0-9]*) ;; *)
        [ "$LW_P_READ" -lt "$_lw_tu" ] || _lw_tbirth=$((LW_P_READ - _lw_tu))
        ;;
    esac
}

lw_traffic_measure() {
    _lw_tdev=$1 _lw_tmax=$2 _lw_tprev=${3:-}
    LW_T_STATE=unknown LW_T_BASE=''
    _lw_tread "$_lw_tdev" || return 1
    _lw_tkey || return 1
    _lw_pnow
    _lw_tnow=$_lw_pn
    LW_T_BASE="$_lw_tdev $_lw_tcalls $_lw_tbirth $_lw_tnow $_lw_ta $_lw_tb $_lw_tc $_lw_td"
    [ -n "$_lw_tprev" ] || return 1
    # the sample: device, session, birth, second, then the four counters
    # shellcheck disable=SC2086  # split the saved fields with globbing disabled
    case $- in
        *f*) set -- $_lw_tprev ;;
        *) set -f; set -- $_lw_tprev; set +f ;;
    esac
    [ $# = 8 ] && [ "$1" = "$_lw_tdev" ] && [ "$2" = "$_lw_tcalls" ] || return 1
    case $3/$_lw_tbirth in
        -/-) ;;
        -/* | */-) return 1 ;;
        *[!0-9/]* | /* | */) return 1 ;;
        *)
            _lw_tgap=$(($3 - _lw_tbirth))
            [ "$_lw_tgap" -ge 0 ] || _lw_tgap=$((0 - _lw_tgap))
            [ "$_lw_tgap" -le "$LW_TRAFFIC_BIRTH_SLACK" ] || return 1
            ;;
    esac
    case $4$5$6$7$8 in '' | *[!0-9]*) return 1 ;; esac
    _lw_tgap=$((_lw_tnow - $4))
    [ "$_lw_tgap" -ge 0 ] && [ "$_lw_tgap" -le "$_lw_tmax" ] || return 1
    # a counter that went back: the device was reset, the sample says nothing
    [ "$_lw_ta" -ge "$5" ] && [ "$_lw_tb" -ge "$6" ] && [ "$_lw_tc" -ge "$7" ] && [ "$_lw_td" -ge "$8" ] || return 1
    _lw_tin=$((_lw_ta - $5 - (_lw_tc - $7)))
    _lw_tout=$((_lw_tb - $6 - (_lw_td - $8)))
    LW_T_STATE=quiet
    if [ "$_lw_tin" -ge "$LW_TRAFFIC_MIN" ] && [ "$_lw_tout" -ge "$LW_TRAFFIC_MIN" ]; then
        LW_T_STATE=traffic
        return 0
    fi
    return 1
}
