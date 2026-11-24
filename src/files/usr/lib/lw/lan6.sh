# shellcheck shell=sh
# shellcheck disable=SC3043  # local is supported by BusyBox ash.
# R74: netifd owns the prefix and addresses; odhcpd owns the advertisements.
LW_LAN6_CONFIG=/var/run/lw-odhcpd

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
    local wan="$1" lan="$2" wan_dev="$3" prefixes entry prefix local_address path
    [ "$(lan6_json "$wan" '@.up')" = true ] || return 1
    [ "$(lan6_json "$wan" '@.l3_device')" = "$wan_dev" ] || return 1
    prefixes=$(lan6_json "$wan" '@["ipv6-prefix"][*]')
    while IFS= read -r entry; do
        prefix=$(lan6_active_prefix "$entry") || continue
        case $prefix in [23]*:*) ;; *) continue ;; esac
        local_address=$(lan6_json "$lan" \
            '@["ipv6-prefix-assignment"][@.address="'"$prefix"'"]["local-address"].address')
        [ -n "$local_address" ] || continue

        # R74a, D198: check the kernel's source-specific route without sending a probe.
        path=$(timeout -k 1 1 ip -6 route get 2001:db8:ffff::1 from "$local_address" 2>/dev/null) || continue
        case " $path " in
            *" dev $wan_dev "*) printf '%s\n' "$local_address"; return 0 ;;
        esac
    done <<EOF_PREFIXES
$prefixes
EOF_PREFIXES
    return 1
}

lan6_managed() {
    [ "$(uci -q get network.lan.lw_ipv6)" = 1 ] &&
        [ "$(uci -q get dhcp.lan.interface)" = lan ] &&
        [ "$(uci -q get dhcp.lan.ra)" = disabled ] &&
        [ "$(uci -q get dhcp.lan.dhcpv6)" = disabled ]
}

lan6_dns() {
    local wan child lan wan_dev cid pdh
    wan=$(lan6_status wwan) || return 1
    [ "$(lan6_json "$wan" '@.up')" = true ] || return 1
    cid=$(lan6_json "$wan" '@.data.cid_6')
    pdh=$(lan6_json "$wan" '@.data.pdh_6')
    case "$cid:${pdh#-}" in :*|*:|*[!0-9:]*) return 1 ;; esac
    wan_dev=$(lan6_json "$wan" '@.l3_device')
    [ -n "$wan_dev" ] || return 1
    lan=$(lan6_status lan) || return 1
    [ "$(lan6_json "$lan" '@.up')" = true ] || return 1

    # R74: DHCPv6 publishes IA_PD or extends the RA /64 only in the absence of IA_PD.
    child=$(lan6_status wwan_6) && lan6_prefix_dns "$child" "$lan" "$wan_dev" && return 0
    lan6_prefix_dns "$wan" "$lan" "$wan_dev"
}

lan6_ra_config() {
    local dir="$1" dns="$2"
    if [ -z "$dns" ]; then
        # R74c: restore odhcpd's native route check for its final RA.
        uci -q -c "$dir" -C "$dir" -t "$dir/delta" batch <<EOF_UCI
set dhcp.lan.ra_default=0
delete dhcp.lan.ra_flags
add_list dhcp.lan.ra_flags=none
set dhcp.lan.ra_dns=0
commit dhcp
EOF_UCI
        return
    fi
    # R74a: the route and prefix are usable. R74c: bound stale addresses after renumbering.
    uci -q -c "$dir" -C "$dir" -t "$dir/delta" batch <<EOF_UCI
set dhcp.lan.ra=server
set dhcp.lan.ra_slaac=1
delete dhcp.lan.ra_flags
add_list dhcp.lan.ra_flags=none
set dhcp.lan.ra_default=2
set dhcp.lan.ra_lifetime=1800
set dhcp.lan.max_preferred_lifetime=1800
set dhcp.lan.ra_dns=1
delete dhcp.lan.dns
add_list dhcp.lan.dns=$dns
commit dhcp
EOF_UCI
}

lan6_configure() (
    mode=$1
    umask 077
    mkdir -p "$LW_LAN6_CONFIG" || exit 1
    flock -x 9 || exit 1
    stage=$(mktemp -d "$LW_LAN6_CONFIG/stage.XXXXXX") || exit 1
    trap 'rm -f "$stage/dhcp" "$stage/delta/dhcp"; rmdir "$stage/delta" "$stage"' EXIT
    mkdir "$stage/delta" || exit 1
    ln -sf /etc/config/network "$LW_LAN6_CONFIG/network"
    ln -sf /etc/config/system "$LW_LAN6_CONFIG/system"
    dhcp=$(uci -N export dhcp) || exit 1
    printf '%s\n' "$dhcp" | sed '1{/^package /d;}' >"$stage/dhcp"
    if lan6_managed; then
        dns=$(lan6_dns) || dns=
        lan6_ra_config "$stage" "$dns" || exit 1
    fi
    [ "$mode" = boot ] || ! cmp -s "$stage/dhcp" "$LW_LAN6_CONFIG/dhcp" || exit 0
    mv -f "$stage/dhcp" "$LW_LAN6_CONFIG/dhcp" || exit 1
    [ "$mode" = boot ] || echo reload
) 9>/var/run/lw-odhcpd.lock
