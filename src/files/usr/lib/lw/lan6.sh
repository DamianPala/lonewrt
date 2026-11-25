# shellcheck shell=sh
# shellcheck disable=SC3043  # local is supported by BusyBox ash.
# R74: netifd owns the prefix and addresses; odhcpd owns the advertisements.
LW_LAN6_CONFIG=/var/run/lw-odhcpd
# R74f: where lw-linkwatch notes that the IPv6 call of the session is gone in the modem
LW_LAN6_LOST=${LW_LAN6_LOST:-/var/run/lw-linkwatch/v6lost}

lan6_status() {
    timeout -k 1 1 ifstatus "$1" 2>/dev/null
}

lan6_json() {
    jsonfilter -s "$1" -e "$2" 2>/dev/null
}

lan6_active_prefix() {
    local assigned
    [ "$(lan6_json "$1" '@.preferred')" != 0 ] || return 1
    [ "$(lan6_json "$1" '@.valid')" != 0 ] || return 1
    assigned=$(lan6_json "$1" '@.assigned.lan')
    [ "$(lan6_json "$assigned" '@.mask')" = 64 ] || return 1
    lan6_json "$assigned" '@.address'
}

lan6_prefix_dns() {
    local wan="$1" lan="$2" wan_dev="$3" prefixes entry prefix local_address path result=1
    case $(lan6_json "$wan" '@.up') in true) ;; false) return 1 ;; *) return 2 ;; esac
    [ "$(lan6_json "$wan" '@.l3_device')" = "$wan_dev" ] || return 1
    prefixes=$(lan6_json "$wan" '@["ipv6-prefix"][*]')
    while IFS= read -r entry; do
        prefix=$(lan6_active_prefix "$entry") || continue
        case $prefix in [23]*:*) ;; *) continue ;; esac
        local_address=$(lan6_json "$lan" \
            '@["ipv6-prefix-assignment"][@.address="'"$prefix"'"]["local-address"].address')
        [ -n "$local_address" ] || continue

        # R74a, D198: check the kernel's source-specific route without sending a probe.
        path=$(timeout -k 1 1 ip -6 route get 2001:db8:ffff::1 from "$local_address" 2>/dev/null) || {
            case $? in 124 | 137) result=2 ;; esac
            continue
        }
        case " $path " in
            *" dev $wan_dev "*) printf '%s\n' "$local_address"; return 0 ;;
        esac
    done <<EOF_PREFIXES
$prefixes
EOF_PREFIXES
    return "$result"
}

lan6_child_dns() {
    local child rc=0
    child=$(timeout -k 1 1 ubus -S call network.interface.wwan_6 status 2>/dev/null) || rc=$?
    # R74c: ubus distinguishes a missing optional DHCPv6 child from an unreadable status.
    case $rc in
        0) lan6_prefix_dns "$child" "$1" "$2" ;;
        4) return 1 ;; # UBUS_STATUS_NOT_FOUND
        *) return 2 ;;
    esac
}

lan6_managed() {
    [ "$(uci -q get /etc/config/network.lan.lw_ipv6)" = 1 ] &&
        [ "$(uci -q -c "$1" -C "$1" get lw_odhcpd.lan.interface)" = lan ] &&
        [ "$(uci -q -c "$1" -C "$1" get lw_odhcpd.lan.ra)" = disabled ] &&
        [ "$(uci -q -c "$1" -C "$1" get lw_odhcpd.lan.dhcpv6)" = disabled ]
}

# lan6_call_lost CID PDH UPTIME: R74f. The watcher confirmed that this session's IPv6 call is gone.
# The flag holds "CID/PDH BIRTH": the call and the second on the uptime clock at which the session
# came up (- when the watcher did not know it). A flag of another call, or of an earlier start of the
# interface with the same numbers (births more than 6 s apart, as in lw-linkwatch), does not count.
lan6_call_lost() {
    local key birth now
    [ -r "$LW_LAN6_LOST" ] || return 1
    read -r key birth _ <"$LW_LAN6_LOST" || return 1
    [ "$key" = "$1/$2" ] || return 1
    case "$birth:$3" in -:* | *:) return 0 ;; esac
    case $birth$3 in *[!0-9]*) return 1 ;; esac
    read -r now _ <"${LW_UPTIME_FILE:-/proc/uptime}"
    now=$((${now%%.*} - $3 - birth))
    [ "$now" -ge -6 ] && [ "$now" -le 6 ]
}

# lan6_dns: the LAN's address for the RDNSS option when the session serves IPv6 (0). 1 is a confirmed
# absence of service (wwan down, no IPv6 call, the watcher's flag, no usable prefix or route). 2 is
# unknown: a session status could not be read or a route lookup timed out (R74c).
lan6_dns() {
    local wan lan wan_dev cid pdh up child_rc=0 wan_rc=0
    wan=$(lan6_status wwan) || return 2
    up=$(lan6_json "$wan" '@.up')
    case $up in true) ;; false) return 1 ;; *) return 2 ;; esac
    cid=$(lan6_json "$wan" '@.data.cid_6')
    pdh=$(lan6_json "$wan" '@.data.pdh_6')
    case "$cid:${pdh#-}" in :*|*:|*[!0-9:]*) return 1 ;; esac
    if [ -r "$LW_LAN6_LOST" ]; then
        ! lan6_call_lost "$cid" "$pdh" "$(lan6_json "$wan" '@.uptime')" || return 1
    fi
    wan_dev=$(lan6_json "$wan" '@.l3_device')
    [ -n "$wan_dev" ] || return 1
    lan=$(lan6_status lan) || return 2
    up=$(lan6_json "$lan" '@.up')
    case $up in true) ;; false) return 1 ;; *) return 2 ;; esac

    # R74: DHCPv6 publishes IA_PD or extends the RA /64 only in the absence of IA_PD.
    lan6_child_dns "$lan" "$wan_dev" || child_rc=$?
    [ "$child_rc" != 0 ] || return 0
    lan6_prefix_dns "$wan" "$lan" "$wan_dev" || wan_rc=$?
    [ "$wan_rc" != 0 ] || return 0
    [ "$child_rc" != 2 ] || return 2
    return "$wan_rc"
}

# lan6_ra_config DIR DNS [withdraw]: the managed LAN's router advertisement options.
lan6_ra_config() {
    local dir="$1" dns="$2" withdraw="$3"
    if [ -n "$withdraw" ]; then
        # R74c: the last advertisement that carries the prefix. odhcpd's final advertisement (the server
        # switched off) never has a prefix option, so this one goes first, with the server still on and
        # the route check restored (zero lifetime when no default route is left). The prefix goes out
        # deprecated when netifd deprecated its address; otherwise odhcpd's floor for the preferred
        # lifetime is 60 s (measured).
        uci -q -c "$dir" -C "$dir" -t "$dir/delta" batch <<EOF_UCI
set lw_odhcpd.lan.ra=server
set lw_odhcpd.lan.ra_slaac=1
set lw_odhcpd.lan.ra_default=0
delete lw_odhcpd.lan.ra_flags
add_list lw_odhcpd.lan.ra_flags=none
set lw_odhcpd.lan.max_preferred_lifetime=60
set lw_odhcpd.lan.ra_dns=0
commit lw_odhcpd
EOF_UCI
        return
    fi
    if [ -z "$dns" ]; then
        # R74c: server off with the route check restored: the final advertisement has router lifetime
        # zero whatever other default routes exist (measured with the pinned odhcpd).
        uci -q -c "$dir" -C "$dir" -t "$dir/delta" batch <<EOF_UCI
set lw_odhcpd.lan.ra_default=0
delete lw_odhcpd.lan.ra_flags
add_list lw_odhcpd.lan.ra_flags=none
set lw_odhcpd.lan.ra_dns=0
commit lw_odhcpd
EOF_UCI
        return
    fi
    # R74a: the route and prefix are usable. R74c: bound stale addresses after renumbering.
    uci -q -c "$dir" -C "$dir" -t "$dir/delta" batch <<EOF_UCI
set lw_odhcpd.lan.ra=server
set lw_odhcpd.lan.ra_slaac=1
delete lw_odhcpd.lan.ra_flags
add_list lw_odhcpd.lan.ra_flags=none
set lw_odhcpd.lan.ra_default=2
set lw_odhcpd.lan.ra_lifetime=1800
set lw_odhcpd.lan.max_preferred_lifetime=1800
set lw_odhcpd.lan.ra_dns=1
delete lw_odhcpd.lan.dns
add_list lw_odhcpd.lan.dns=$dns
commit lw_odhcpd
EOF_UCI
}

# R74c, R74f: what the init script still owes odhcpd. `pending` (RAM) holds the target of the config
# installed by the last lan6_configure (active, w or off) until the init script has sent the signal and
# the signal request succeeded (lan6_applied); `phase` holds the target odhcpd is known to run. Both
# are read and written with builtins, so an IPv4-only router that never serves IPv6 pays nothing for
# them. A reload that did not reach odhcpd therefore does not look applied: the next run signals
# again although the RAM copy already has the bytes.

# lan6_applied: the signal for the installed config reached odhcpd. After the withdrawal config the
# final one is still owed, so the mark stays (as `off`): a run killed in the wait is finished by the
# next one, with no new event of the session.
lan6_applied() {
    local t
    [ -r "$LW_LAN6_CONFIG/pending" ] || return 0
    read -r t <"$LW_LAN6_CONFIG/pending" || return 0
    printf '%s\n' "$t" >"$LW_LAN6_CONFIG/phase" || return 1
    if [ "$t" = w ]; then
        echo off >"$LW_LAN6_CONFIG/pending"
    else
        rm -f "$LW_LAN6_CONFIG/pending"
    fi
}

# lan6_configure boot|event: rebuilds the RAM copy from the persistent config and the session. At
# event it prints what to do with odhcpd: nothing, `reload` (one signal), `withdraw` (R74c: a signal,
# a wait, and then lan6_configure again for the final one) or `unknown` (incomplete session data).
# A pending signal is printed again.
lan6_configure() (
    mode=$1
    umask 077
    mkdir -p "$LW_LAN6_CONFIG" || exit 1
    flock -x 9 || exit 1
    # A run killed after mktemp leaves its stage behind; this run holds the lock, so any is stale.
    for stage in "$LW_LAN6_CONFIG"/stage.*; do
        [ ! -d "$stage" ] || rm -rf "$stage"
    done
    cur=
    # the start of odhcpd reads the config itself, so at boot nothing is known to be running
    [ "$mode" = boot ] || [ ! -r "$LW_LAN6_CONFIG/phase" ] || read -r cur <"$LW_LAN6_CONFIG/phase" || :
    stage=$(mktemp -d "$LW_LAN6_CONFIG/stage.XXXXXX") || exit 1
    trap 'rm -f "$stage/lw_odhcpd" "$stage/delta/lw_odhcpd"; rmdir "$stage/delta" "$stage"' EXIT
    mkdir "$stage/delta" || exit 1
    ln -sf /etc/config/network "$LW_LAN6_CONFIG/network"
    ln -sf /etc/config/system "$LW_LAN6_CONFIG/system"
    # R74e: exporting by path bypasses UCI's staged changes for the named package.
    dhcp=$(uci -P /dev/null -N export /etc/config/dhcp) || exit 1
    # The stage uses a distinct package name so its edits cannot merge the global dhcp delta.
    printf '%s\n' "$dhcp" | sed '1{/^package /d;}' >"$stage/lw_odhcpd"
    target=off
    if lan6_managed "$stage"; then
        rc=0
        dns=$(lan6_dns) || rc=$?
        # R74c: unknown keeps the running state and sends no signal. The init script
        # fails on the word, so the watcher keeps its marker and asks again.
        if [ "$rc" = 2 ] && [ "$mode" != boot ]; then
            echo unknown
            exit 0
        fi
        withdraw=
        if [ "$rc" = 0 ]; then
            target=active
        else
            dns=
            # R74c: a loss of the served LAN is first the withdrawal, then the server off
            case $cur in
                active) target=w withdraw=1 ;;
            esac
        fi
        lan6_ra_config "$stage" "$dns" "$withdraw" || exit 1
    fi
    if [ "$mode" = boot ]; then
        mv -f "$stage/lw_odhcpd" "$LW_LAN6_CONFIG/dhcp" || exit 1
        printf '%s\n' "$target" >"$LW_LAN6_CONFIG/phase"
        [ ! -e "$LW_LAN6_CONFIG/pending" ] || rm -f "$LW_LAN6_CONFIG/pending"
        exit 0
    fi
    install=1
    if cmp -s "$stage/lw_odhcpd" "$LW_LAN6_CONFIG/dhcp"; then
        [ -e "$LW_LAN6_CONFIG/pending" ] || exit 0
        install=
    fi
    # R74c: write the mark before a rename. Even on a match, an interrupted rename could have
    # left a mark for a different configuration that never made it into place.
    printf '%s\n' "$target" >"$LW_LAN6_CONFIG/pending" || exit 1
    [ -z "$install" ] || mv -f "$stage/lw_odhcpd" "$LW_LAN6_CONFIG/dhcp" || exit 1
    if [ "$target" = w ]; then echo withdraw; else echo reload; fi
) 9>/var/run/lw-odhcpd.lock
