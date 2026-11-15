# Wi-Fi names and passwords, connected devices and the data of the month (SPEC R43, R44, R44a,
# D58, D59): the code behind /wifi, /devices and the data line of /status. Sourced by
# /usr/sbin/lw-notify after notify.sh. POSIX sh for busybox ash; every name has the nt_ prefix.
# shellcheck disable=SC2034,SC2153  # settings read by /usr/sbin/lw-notify; NT_CB* are set there
#
# Everything here only reads: uci for the networks, ubus for the Wi-Fi stations, the ARP table for
# the cable, dnsmasq's lease file for the names and `nlbw` (nlbwmon) for the counters. Scratch files
# live in $NT_RUN (RAM), so nothing reaches flash or syslog (R34c); the one exception is the list of
# remembered DHCP names (R44b), written at most once a day.

NT_LEASES=${LW_NOTIFY_LEASES:-/tmp/dhcp.leases}
NT_ARP=${LW_NOTIFY_ARP:-/proc/net/arp}
# nlbwmon books the router's own traffic (the speed tests) under the all-zero MAC
NT_SELF_MAC=00:00:00:00:00:00
# Devices listed by /devices (R44)
NT_DEV_MAX=20

# nt_clean TEXT: one line without control characters.
nt_clean() { printf '%s' "$1" | tr -d '\000-\037\177'; }

# nt_wifi_aps [raw]: the networks that are switched on, as lines "s:<name>", "k:<password>",
# "e:<encryption>", "h:<1 when hidden>" and an empty "b:" (which ends a network). Disabled networks
# and disabled radios, and everything that is not an access point, are left out (R43). Name and
# password are HTML text (R37g); with "raw" they are the text itself, for the QR code.
nt_wifi_aps() {
    _wraw=${1-}
    uci show wireless 2>/dev/null | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface$/\1/p' |
        while read -r _ws; do
            [ "$(uci -q get "wireless.$_ws.disabled")" != 1 ] || continue
            case $(uci -q get "wireless.$_ws.mode") in ap | '') ;; *) continue ;; esac
            _wd=$(uci -q get "wireless.$_ws.device")
            [ "$(uci -q get "wireless.$_wd.disabled")" != 1 ] || continue
            _wk=$(uci -q get "wireless.$_ws.key") || _wk=
            [ -n "$_wk" ] || _wk=$(uci -q get "wireless.$_ws.sae_password") || _wk=
            printf 's:%s\nk:%s\ne:%s\nh:%s\nb:\n' \
                "$(nt_wifi_val "$(uci -q get "wireless.$_ws.ssid")")" "$(nt_wifi_val "$_wk")" \
                "$(uci -q get "wireless.$_ws.encryption")" "$(uci -q get "wireless.$_ws.hidden")"
        done
}

# nt_wifi_val TEXT: a name or password cleaned of control characters, as HTML text, or as it is
# when nt_wifi_aps was asked for "raw".
nt_wifi_val() {
    if [ "$_wraw" = raw ]; then nt_clean "$1"; else nt_h "$(nt_clean "$1")"; fi
}

# nt_wifi_text [caption] (R43): names and passwords as the guests need them, each in a <code> tag,
# which a tap on the phone copies (D83). Networks with the same name and password are one entry (the
# radios differ, the guest does not care); a further network is its own paragraph and says "same
# password" when it is. No band is named: the guest picks the network by its name. With "caption"
# the text is the caption of the QR photo: "Password: none" for an open network, and a last line
# that tells the reader what to do with the code, so the message makes sense when it is forwarded.
nt_wifi_text() {
    nt_wifi_aps | awk -v cap="${1-}" '
        /^s:/ { ssid = substr($0, 3) }
        /^k:/ { key = substr($0, 3) }
        /^e:/ { enc = substr($0, 3) }
        /^b:/ {
            if (enc == "none" || enc == "owe") key = ""
            id = ssid SUBSEP key
            if (!(id in seen)) { seen[id] = ++ng; gs[ng] = ssid; gk[ng] = key }
        }
        END {
            if (ng == 0) { print "📶 No Wi-Fi network is switched on."; exit }
            print "📶 <b>Wi-Fi</b>"
            for (g = 1; g <= ng; g++) {
                if (g > 1) print ""
                printf "Name: <code>%s</code>\n", gs[g]
                if (gk[g] == "") print (cap == "caption" ? "Password: none" : "No password")
                else if (g > 1 && gk[g] == gk[1]) print "Password: same password"
                else printf "Password: <code>%s</code>\n", gk[g]
            }
            if (cap == "caption") {
                print ""
                print "Scan the code with the phone camera to join" \
                    (ng > 1 ? " the first network." : ".")
            }
        }'
}

# nt_qr_esc TEXT: TEXT for a field of the Wi-Fi QR code: \ ; , : and " each get a backslash in front
# (the format of the WIFI: string that phone cameras read). Not for HTML.
nt_qr_esc() { printf '%s' "$1" | sed 's/[\\;,:"]/\\&/g'; }

# nt_qr_wifi SSID KEY HIDDEN (R51): the text of the QR code that makes a phone join the network.
# The type is WPA, or nopass for a network without a key (then there is no P field); H:true marks
# a hidden name.
nt_qr_wifi() {
    if [ -n "$2" ]; then
        _qs="WIFI:T:WPA;S:$(nt_qr_esc "$1");P:$(nt_qr_esc "$2");"
    else
        _qs="WIFI:T:nopass;S:$(nt_qr_esc "$1");"
    fi
    [ "$3" != 1 ] || _qs="${_qs}H:true;"
    printf '%s;' "$_qs"
}

# nt_wifi_first: the first network as /wifi lists it, as the text of the QR code in NT_WQR; fails
# when no network is switched on. The name and the password are read as they are, not as HTML.
nt_wifi_first() {
    _wfs='' _wfk='' _wfe='' _wfh=''
    _wfn=0
    _wfa=$(nt_wifi_aps raw)
    while IFS= read -r _wfl; do
        case $_wfl in
            s:*) _wfs=${_wfl#s:} ;;
            k:*) _wfk=${_wfl#k:} ;;
            e:*) _wfe=${_wfl#e:} ;;
            h:*) _wfh=${_wfl#h:} ;;
            b:*) _wfn=1 && break ;;
        esac
    done <<EOF
$_wfa
EOF
    [ "$_wfn" = 1 ] || return 1
    case $_wfe in none | owe) _wfk='' ;; esac
    NT_WQR=$(nt_qr_wifi "$_wfs" "$_wfk" "$_wfh")
}

# nt_qr_pgm: a QR code in the text form of `qrencode -t ASCII` (two characters per module, "#" is a
# dark module, a margin around it) on stdin as a plain PGM (P2) picture on stdout: every module a
# square of PX by PX pixels, 0 for dark and 255 for light. PX is 500 divided by the modules in a
# line, but at least 8 and at most 12, so the picture is about 400 to 600 pixels wide and a phone
# camera reads it from a screen. Fails, printing nothing, when the text is not a square.
nt_qr_pgm() {
    awk '
        { rows[++r] = $0; if (length($0) > w) w = length($0) }
        END {
            n = int((w + 1) / 2)
            if (n < 21 || n != r) exit 1
            px = int(500 / n)
            if (px > 12) px = 12
            if (px < 8) px = 8
            for (k = 0; k < px; k++) { dark = dark "0 "; light = light "255 " }
            print "P2"
            print n * px, n * px
            print 255
            for (i = 1; i <= n; i++) {
                line = ""
                for (j = 0; j < n; j++)
                    line = line (substr(rows[i], 2 * j + 1, 1) == "#" ? dark : light)
                for (k = 0; k < px; k++) print line
            }
        }'
}

# nt_qr_image QR (R51): the picture of the QR code with the text QR, in the file NT_IMG with the
# content type NT_IMG_TYPE (image/jpeg); fails, leaving no file, when it cannot be made. This is
# the one place that knows the image format and the tools that make it (D91): qrencode draws the
# code as text (the package has no PNG output), nt_qr_pgm turns it into a picture, and cjpeg
# (libjpeg-turbo-utils) packs that as a JPEG of quality 90, which Telegram takes as a photo. The
# margin is 4 modules. The text goes in through stdin, not as an argument that `ps` would show,
# and the picture is read from a pipe, so no PGM file of a megabyte lands in RAM.
nt_qr_image() {
    NT_IMG=$NT_RUN/qr.$$.jpg
    NT_IMG_TYPE=image/jpeg
    rm -f "$NT_IMG"
    _qra=$(printf '%s' "$1" | qrencode -t ASCII -m 4 2>/dev/null) || _qra=
    [ -n "$_qra" ] || return 1
    if printf '%s\n' "$_qra" | nt_qr_pgm |
        cjpeg -quality 90 -grayscale -outfile "$NT_IMG" >/dev/null 2>&1 && [ -s "$NT_IMG" ]; then
        return 0
    fi
    rm -f "$NT_IMG"
    return 1
}

# Telegram takes 1024 characters in a caption after the markup is read. The length here counts the
# markup and the entities too, so it is never less than Telegram's.
NT_CAPTION_MAX=1000

# nt_wifi_photo (R51): /wifi as a photo, the QR code of the first network with the caption. Returns
# 0 when it went out, 1 when the network failed (the answer to a command is not repeated, as with
# nt_send), 2 when there is no photo to send (no image, a caption that is too long, or Telegram
# refused it); the caller then sends the text. The log gets one ASCII line for the third kind of
# failure, with no name, no password and no token.
nt_wifi_photo() {
    nt_wifi_first || return 2
    _wpc=$(nt_wifi_text caption)
    if [ "${#_wpc}" -gt "$NT_CAPTION_MAX" ]; then
        lw_log "$NT_TAG" "Wi-Fi photo not sent: the caption is too long, sent as text"
        return 2
    fi
    if ! nt_qr_image "$NT_WQR"; then
        lw_log "$NT_TAG" "Wi-Fi photo not sent: no QR image could be made, sent as text"
        return 2
    fi
    _wpr=0
    nt_photo "$NT_IMG" "$NT_IMG_TYPE" "$_wpc" || _wpr=$?
    rm -f "$NT_IMG"
    if [ "$_wpr" = 2 ]; then
        lw_log "$NT_TAG" "Wi-Fi photo not sent: Telegram refused it (HTTP 400), sent as text"
    fi
    return "$_wpr"
}

# nt_wifi_cmd (R43, R51): the photo, and the text when there is no photo.
nt_wifi_cmd() {
    _wcr=0
    nt_wifi_photo || _wcr=$?
    case $_wcr in
        0) return 0 ;;
        1) return 1 ;;
    esac
    nt_send "$(nt_wifi_text)"
}

# nt_wifi_stations: "<mac> wifi" for every device associated on a Wi-Fi network. The list does not
# name the band any more (R44); it only tells the devices that are connected now.
nt_wifi_stations() {
    _wl=$(timeout 5 ubus list 'hostapd.*' 2>/dev/null) || return 0
    for _wo in $_wl; do
        _wj=$(timeout 5 ubus call "$_wo" get_clients 2>/dev/null) || continue
        for _wm in $(printf '%s\n' "$_wj" | grep -oiE '([0-9a-f]{2}:){5}[0-9a-f]{2}' |
            tr 'A-F' 'a-f'); do
            [ "$(printf '%s\n' "$_wj" | jsonfilter -e "@.clients['$_wm'].assoc" 2>/dev/null)" = true ] ||
                continue
            echo "$_wm wifi"
        done
    done
}

# nt_cable_stations: "<mac> cable" for the neighbours of the LAN bridge that are not on Wi-Fi. An
# entry stays in the ARP table for a while after the cable is pulled, so a device can show up late.
nt_cable_stations() {
    _cd=$(uci -q get network.lan.device) || _cd=br-lan
    awk -v dev="${_cd:-br-lan}" 'NR > 1 && $6 == dev && $3 == "0x2" { print tolower($4) }' \
        "$NT_ARP" 2>/dev/null | sort -u | while read -r _cm; do
        grep -q "^$_cm " "$NT_RUN/wifi_stations" || echo "$_cm cable"
    done
}

# nt_data_read (R44, R44a): the month's counters per MAC from nlbwmon into $NT_RUN/usage as lines
# "<mac> <bytes>", NT_DATA = ok, noclock (ntpd has not set the month yet) or unknown (nlbwmon does
# not answer), NT_DATA_TOTAL = the sum in bytes.
nt_data_read() {
    NT_DATA=unknown
    NT_DATA_TOTAL=
    : >"$NT_RUN/usage"
    if ! nt_clock_ok; then
        NT_DATA=noclock
        return 0
    fi
    _nj=$(timeout 5 nlbw -c json -g mac 2>/dev/null) || return 0
    _nc=$(printf '%s\n' "$_nj" | jsonfilter -e '@.columns[*]' 2>/dev/null | tr '\n' ' ')
    [ -n "$_nc" ] || return 0
    printf '%s\n' "$_nj" | jsonfilter -e '@.data[*]' 2>/dev/null | awk -v cols="$_nc" '
        BEGIN {
            n = split(cols, c, " ")
            for (i = 1; i <= n; i++) {
                if (c[i] == "mac") m = i
                if (c[i] == "rx_bytes") r = i
                if (c[i] == "tx_bytes") t = i
            }
        }
        m && r && t {
            gsub(/[][" ]/, "")
            split($0, f, ",")
            printf "%s %.0f\n", tolower(f[m]), f[r] + f[t]
            sum += f[r] + f[t]
        }
        END { if (m && r && t) printf "#total %.0f\n", sum }' >"$NT_RUN/usage"
    NT_DATA_TOTAL=$(sed -n 's/^#total //p' "$NT_RUN/usage")
    [ -z "$NT_DATA_TOTAL" ] || NT_DATA=ok
}

# nt_data_gb: "42 GB", or "&lt;0.1 GB" for less than 50 MB, after nt_data_read; HTML text (R37g).
nt_data_gb() {
    awk -v b="$NT_DATA_TOTAL" 'BEGIN {
        if (b < 5e7) printf "&lt;0.1 GB"
        else if (b < 1e10) printf "%.1f GB", b / 1e9
        else printf "%.0f GB", b / 1e9 }'
}

# nt_data_summary: "42 GB (since 1 Nov)" after nt_data_read, or why there is no number.
nt_data_summary() {
    case $NT_DATA in
        ok) printf '%s (since 1 %s)' "$(nt_data_gb)" "$(date -d "@$(nt_wall)" +%b)" ;;
        noclock) printf 'unknown (the router clock is not set yet)' ;;
        *) printf unknown ;;
    esac
}

# nt_data_status_line: the line of /status, with its own line break in front.
nt_data_status_line() {
    nt_data_read
    case $NT_DATA in
        noclock) NT_DATA=unknown ;;
    esac
    printf '\n📊 Data this month: %s' "$(nt_data_summary)"
}

# Names of the DHCP clients (R44b). dnsmasq forgets a client when its lease runs out and at every
# restart of the router, so the names are kept apart: $NT_NAMES in RAM is the working copy, lines
# "<mac> <name>"; $NT_NAMES_FLASH is the same list behind a first line with the epoch of the last
# write. Flash is written only when the list changed and the last write is a day old
# (NT_NAMES_EVERY, the rule of the counters in R44a), once more when the service stops or before a
# restart asked from the chat, and never before ntpd set the clock (the stamp would mean nothing).
# A power cut loses at most the names that came in since the last write, as it loses a day of
# counters. The list holds only MACs with traffic in the current month or a lease now, so a new
# month starts it afresh.
NT_NAMES=$NT_RUN/names
NT_NAMES_FLASH=$NT_DIR/names
NT_NAMES_EVERY=${LW_NOTIFY_NAMES_EVERY:-86400}

# nt_names_merge [prune]: the leases of dnsmasq into the working copy (a lease with a name replaces
# the old name, one without keeps it). With "prune" the list drops every MAC that has neither
# traffic in $NT_RUN/usage (so nt_data_read must have said ok) nor a lease. A change marks the copy dirty.
nt_names_merge() {
    [ -f "$NT_NAMES" ] || tail -n +2 "$NT_NAMES_FLASH" >"$NT_NAMES" 2>/dev/null || :
    {
        sed 's/^/O /' "$NT_NAMES"
        awk '$4 != "*" && $4 != "" { print "L", tolower($2), $4 }' "$NT_LEASES" 2>/dev/null |
            tr -d '\001-\010\013-\037\177'
        [ "${1:-}" != prune ] || sed -n 's/^\([0-9a-f:]*\) [0-9]*$/U \1/p' "$NT_RUN/usage"
    } | awk -v prune="$([ "${1:-}" = prune ] && echo 1 || echo 0)" '
        $1 == "O" { name[$2] = $3 }
        $1 == "L" { name[$2] = $3; leased[$2] = 1 }
        $1 == "U" { used[$2] = 1 }
        END { for (m in name) if (!prune || (m in used) || (m in leased)) print m, name[m] }' |
        sort >"$NT_NAMES.new"
    if [ "$(cat "$NT_NAMES.new")" = "$(cat "$NT_NAMES")" ]; then
        rm -f "$NT_NAMES.new"
    else
        mv -f "$NT_NAMES.new" "$NT_NAMES"
        : >"$NT_RUN/names_dirty"
    fi
}

# nt_names_save [force|read]: the working copy to flash when it changed and the write is due (see
# above). Before a due write the list is pruned against the month's counters, when nlbwmon answers;
# "read" says the caller has read them already. "force" (stop, restart) writes at once and skips the
# pruning, which needs a call that may take seconds.
nt_names_save() {
    [ -f "$NT_RUN/names_dirty" ] || return 0
    nt_clock_ok || return 0
    _nsn=$(nt_wall)
    if [ "${1:-}" != force ]; then
        _nsd=$((_nsn - $(nt_get "$NT_NAMES_FLASH" 0)))
        [ "$_nsd" -lt 0 ] || [ "$_nsd" -ge "$NT_NAMES_EVERY" ] || return 0
        if [ "${1:-}" != read ]; then
            nt_data_read
            [ "$NT_DATA" != ok ] || nt_names_merge prune
        fi
    fi
    mkdir -p "$NT_DIR"
    { echo "$_nsn"; cat "$NT_NAMES"; } | lw_write_atomic "$NT_NAMES_FLASH" &&
        rm -f "$NT_RUN/names_dirty"
}

# nt_names_poll: one look at the leases per pass of the service; the file is read again only when it
# changed, and the flash is touched only by nt_names_save.
nt_names_poll() {
    _nps=$(md5sum <"$NT_LEASES" 2>/dev/null) || _nps=
    if [ "$_nps" != "$(cat "$NT_RUN/leases.sum" 2>/dev/null)" ]; then
        nt_names_merge
        printf '%s\n' "$_nps" >"$NT_RUN/leases.sum"
    fi
    nt_names_save
}

# nt_devices_list (R44, R44b): the lines of /devices after the heading, from $NT_RUN/stations
# (connected now: "<mac> wifi or cable"), $NT_RUN/usage and the names. Prints "T <devices>
# <connected now> <listed>" and then the "C " lines of the connected devices and the "O " lines of
# the others, each group biggest first (equal sizes by name), the two groups together cut to
# NT_DEV_MAX entries, the smallest of either group going first. Without counters (ok = 0) only the
# connected devices are known and none has a size. The router's own MAC is not a device.
nt_devices_list() {
    {
        sed 's/^/S /' "$NT_RUN/stations"
        sed -n 's/^\([0-9a-f:]*\) \([0-9]*\)$/U \1 \2/p' "$NT_RUN/usage"
        sed 's/^/N /' "$NT_NAMES"
        # R50: the names the owner gave come last, so they replace the DHCP names
        nt_nm_lines
    } | awk -v ok="$([ "$NT_DATA" = ok ] && echo 1 || echo 0)" -v max="$NT_DEV_MAX" \
        -v self="$NT_SELF_MAC" '
        function gb(b) { return b < 5e7 ? "<0.1 GB" : sprintf("%.1f GB", b / 1e9) }
        function less(a, b) {
            return bytes[a] < bytes[b] || (bytes[a] == bytes[b] && text[a] > text[b])
        }
        function add(m,    nm) {
            nm = (m in name) ? name[m] : "Unknown device (…" substr(m, 13) ")"
            n++
            mac[n] = m
            bytes[n] = (m in used) ? used[m] : 0
            if (bytes[n] > 1e15) bytes[n] = 1e15
            isconn[n] = (m in kind)
            text[n] = "• " nm (ok ? " · " gb(bytes[n]) : "")
        }
        $1 == "N" { name[$2] = substr($0, length($1 $2) + 3) }
        $1 == "U" { used[$2] = $3 }
        $1 == "S" { kind[$2] = substr($0, length($1 $2) + 3) }
        END {
            for (m in kind) add(m)
            if (ok) for (m in used) if (!(m in kind) && m != self && used[m] > 0) add(m)
            # insertion sort, biggest first
            for (i = 2; i <= n; i++) {
                for (j = i; j > 1 && less(j - 1, j); j--) {
                    t = mac[j]; mac[j] = mac[j - 1]; mac[j - 1] = t
                    t = bytes[j]; bytes[j] = bytes[j - 1]; bytes[j - 1] = t
                    t = text[j]; text[j] = text[j - 1]; text[j - 1] = t
                    t = isconn[j]; isconn[j] = isconn[j - 1]; isconn[j - 1] = t
                }
            }
            for (i = 1; i <= n; i++) if (isconn[i]) conn++
            shown = n < max ? n : max
            printf "T %d %d %d\n", n, conn, shown
            for (i = 1; i <= shown; i++) if (isconn[i]) print "C " text[i]
            for (i = 1; i <= shown; i++) if (!isconn[i]) print "O " text[i]
            # R50: every device, uncut, for the list of names.sh: "M <mac> n" for one with a name
            # (DHCP or ours), "M <mac> u" for one without, the connected first
            for (i = 1; i <= n; i++) if (isconn[i]) print "M " mac[i], (mac[i] in name) ? "n" : "u"
            for (i = 1; i <= n; i++) if (!isconn[i]) print "M " mac[i], (mac[i] in name) ? "n" : "u"
        }'
}

# nt_devices_text (R44): the heading with the data of the month, the devices in two groups, then the
# router's own traffic as a line of its own. Names come from DHCP, so every device line is escaped
# (R37g); the tags are ours.
nt_devices_text() {
    nt_data_read
    nt_names_merge "$([ "$NT_DATA" = ok ] && echo prune)"
    nt_names_save read
    nt_wifi_stations >"$NT_RUN/wifi_stations"
    {
        cat "$NT_RUN/wifi_stations"
        nt_cable_stations
    } >"$NT_RUN/stations"
    nt_devices_list >"$NT_RUN/dev_list"
    read -r _ _dn _dc _ds <"$NT_RUN/dev_list"
    _dcon=$(sed -n 's/^C //p' "$NT_RUN/dev_list" | nt_hf)
    _doff=$(sed -n 's/^O //p' "$NT_RUN/dev_list" | nt_hf)
    if [ "$NT_DATA" = ok ]; then
        _dtxt="📱 <b>Devices</b> · $(nt_data_gb) this month (since 1 $(date -d "@$(nt_wall)" +%b))"
        [ -z "$_dcon" ] || _dtxt="$_dtxt

<b>Connected now ($_dc)</b>
$_dcon"
        [ -z "$_doff" ] || _dtxt="$_dtxt

<b>Earlier this month ($((_dn - _dc)))</b>
$_doff"
    else
        _dtxt="📱 <b>Devices</b> · data this month: $(nt_data_summary)

<b>Connected now ($_dc)</b>"
        [ -z "$_dcon" ] || _dtxt="$_dtxt
$_dcon"
    fi
    [ "$_dn" -le "$_ds" ] || _dtxt="$_dtxt
…and $((_dn - _ds)) more"
    _dr=$(sed -n "s/^$NT_SELF_MAC \\([0-9][0-9]*\\)\$/\\1/p" "$NT_RUN/usage")
    if [ "$NT_DATA" = ok ] && [ "${_dr:-0}" -gt 0 ]; then
        _drg=$(awk -v b="$_dr" '
            BEGIN { printf "%s", b < 5e7 ? "&lt;0.1 GB" : sprintf("%.1f GB", b / 1e9) }')
        _dtxt="$_dtxt

• Router itself · $_drg"
    fi
    printf '%s' "$_dtxt"
}

# the button under the list opens the picker of R50 (names.sh)
nt_devices_cmd() { nt_send "$(nt_devices_text)" "$(nt_nm_markup)"; }

# nt_data_commit: write the counters to flash now; nlbwmon does it itself once a day and when it is
# stopped, this one is for the moment before a restart we start ourselves (R44a).
nt_data_commit() { timeout 10 nlbw -c commit >/dev/null 2>&1 || :; }
