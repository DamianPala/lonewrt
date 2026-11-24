# shellcheck shell=bash
# Sourced by build.sh and tests/vm/build-image.sh (SPEC R12d to R12f, D82, D172, D192): derives the
# image's /lib/netifd/proto/qmi.sh from the `uqmi` package that the ImageBuilder installs, and checks
# after the build that the image holds exactly that file with the same edits. The repository keeps
# no copy of the file (it is GPL-2.0, the repository is MIT): only the anchors below and lonewrt's
# own text in qmi-edits/. The caller sets LW_ROOTFS and has a die().

QMI_SH_REL=lib/netifd/proto/qmi.sh
# lw_pin VARIABLE DEFAULT: the pin a build uses. R12g, D205: the variable replaces the pin only
# under the test suite (tests/build/lib.bash exports LW_TESTS=1); with it set any other way the build
# stops, naming it, before anything is derived. A knob that works in a release build would let any
# file pass the pin. Shared with watchcat-handler.sh (R14c), so there is one mechanism.
lw_pin() {
    local var=$1 default=$2
    if [ -n "${!var+x}" ] && [ "${LW_TESTS:-}" != 1 ]; then
        echo "build: error: $var is set, and it can replace a pin of the build only under the test suite" \
            "(SPEC R12g, D205): unset $var" >&2
        return 1
    fi
    printf '%s\n' "${!var:-$default}"
}

# R12e, D192: the sha256 of the stock file the edits were reviewed against (uqmi 2025.07.30, OpenWrt
# 25.12.6). LW_QMI_SHA256 is for the tests, which derive from made-up files (lw_pin).
QMI_STOCK_SHA256=$(lw_pin LW_QMI_SHA256 073b855cb15d6cdffb0c1de2f3fec9785796d6399c9f8ce5fcd5c2fbbe6fa6d4) || exit 1
# lonewrt's text that goes into the file
QMI_EDITS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qmi-edits

# Edit 1 (R12d (1)): the line that scans the network for 26 s after the mode set is dropped, the
# comment line above it stays
QMI_SCAN_PATTERN=--network-scan
# Edit 2 (R12d (2)): the lines from the start anchor up to, not including, the end anchor are the
# call negotiation of the stock handler (profile write, one client and call per family); they are
# replaced by qmi-edits/call.sh, and qmi-edits/functions.sh goes in front of the function anchor.
# Each anchor is a whole line, found exactly once.
QMI_A_NEG_START=$'\techo "Starting network $interface"'
QMI_A_NEG_END=$'\techo "Setting up $ifname"'
QMI_A_FUNCS='qmi_wds_stop() {'
# Edit 3 (R12d (3)): the repair of profile 1 runs before the first registration call
QMI_A_REGISTER=$'\tuqmi -s -d "$device" -t 20000 --network-register > /dev/null 2>&1'
QMI_N_REGISTER=$'\tlw_repair'
# Edit 4 (R12d (3), R76b): the IPv6 child leaves the 464XLAT to the translation unless a native IPv4
# call exists, and the IPv6 settings of the modem are used only when they are complete (R73j)
QMI_A_464=$'\t\t\t[ "$pdptype" = "ipv4v6" ] && json_add_string iface_464xlat "0"'
QMI_N_464=$'\t\t\t[ -n "$pdh_4" ] && json_add_string iface_464xlat "0"'
QMI_A_V6=$'\t\tif [ -z "$dhcpv6" -o "$dhcpv6" = 0 ]; then'
QMI_N_V6=$'\t\tif { [ -z "$dhcpv6" ] || [ "$dhcpv6" = 0 ]; } && lw_v6_ok; then'
# Edit 5 (R73j): the stock read of the IPv6 settings, a second one after lw_v6_ok's, is replaced by
# the set lw_v6_ok checked, so what is published is what was verified
QMI_A_V6LOAD=$'\t\t\tjson_load "$(uqmi -s -d $device -t 1000 --set-client-id wds,$cid_6 --get-current-settings)"'
QMI_N_V6LOAD=$'\t\t\tjson_load "$lw_v6_json"'
# The IPv4 child block ends the setup function: with no native IPv4 call (a session of IPv6 alone)
# its `[ -n "$pdh_4" ] && {` would make the function, and so the setup, return 1. The same line is
# in the publish block above, hence it is the one after the IPv6 settings branch.
QMI_A_V4=$'\t[ -n "$pdh_4" ] && {'
QMI_N_V4=$'\t[ -z "$pdh_4" ] || {'

# qmi_sh_n FILE: the same parser as render.py's R6 check (busybox ash of the OpenWrt rootfs)
qmi_sh_n() {
    local root=${LW_ROOTFS:-}
    if [ -x "$root/bin/busybox" ]; then
        "$root/lib/ld-musl-x86_64.so.1" --library-path "$root/lib:$root/usr/lib" \
            "$root/bin/busybox" sh -n "$1"
    else
        busybox sh -n "$1"
    fi
}

# qmi_expect_once FILE NAME LABEL LINE: LINE is a whole line of FILE exactly once, else stop with the
# package's file name (R12d)
qmi_expect_once() {
    local n
    n=$(grep -cxF -e "$4" "$1" || true)
    [ "$n" = 1 ] ||
        die "/$QMI_SH_REL of $2 has $n lines equal to the anchor $3, expected exactly 1" \
            "(SPEC R12d, D82): read the new file and change the edits (docs/development.md)"
}

# qmi_transform IN OUT NAME: OUT = the stock file IN with the edits. Stops, with OUT not written,
# when IN has another sha256 than the reviewed one (R12e), an anchor is not there exactly once, or
# the start anchor of the replaced block does not come before its end anchor.
qmi_transform() {
    local in=$1 out=$2 name=$3 sum n line state=0 seen_v6=0 tmp
    sum=$(sha256sum "$in" | cut -d' ' -f1)
    [ "$sum" = "$QMI_STOCK_SHA256" ] ||
        die "/$QMI_SH_REL of $name has sha256 $sum, the edits were reviewed against $QMI_STOCK_SHA256" \
            "(SPEC R12e, D192): read the new file, change the edits and the pin"
    n=$(grep -cF -e "$QMI_SCAN_PATTERN" "$in" || true)
    if [ "$n" != 1 ]; then
        die "/$QMI_SH_REL of $name has $n lines with $QMI_SCAN_PATTERN, expected exactly 1" \
            "(SPEC D82): read the new file and measure ifup again (docs/development.md)"
    fi
    qmi_expect_once "$in" "$name" "start of the negotiation" "$QMI_A_NEG_START"
    qmi_expect_once "$in" "$name" "end of the negotiation" "$QMI_A_NEG_END"
    qmi_expect_once "$in" "$name" "teardown function" "$QMI_A_FUNCS"
    qmi_expect_once "$in" "$name" "registration call" "$QMI_A_REGISTER"
    qmi_expect_once "$in" "$name" "464XLAT switch" "$QMI_A_464"
    qmi_expect_once "$in" "$name" "IPv6 settings branch" "$QMI_A_V6"
    qmi_expect_once "$in" "$name" "IPv6 settings read" "$QMI_A_V6LOAD"
    n=$(awk -v after="$QMI_A_V6" -v a="$QMI_A_V4" '$0 == after { f = 1 } f && $0 == a { n++ } END { print n + 0 }' "$in")
    [ "$n" = 1 ] ||
        die "/$QMI_SH_REL of $name has $n lines equal to the anchor IPv4 child block after the IPv6 settings branch," \
            "expected exactly 1 (SPEC R12d): read the new file and change the edits (docs/development.md)"
    [ "$(grep -nxF -e "$QMI_A_NEG_START" "$in" | cut -d: -f1)" -lt \
        "$(grep -nxF -e "$QMI_A_NEG_END" "$in" | cut -d: -f1)" ] ||
        die "/$QMI_SH_REL of $name has the end of the negotiation before its start (SPEC R12d)"
    tmp=$(mktemp "$out.XXXXXX") || die "cannot write $out"
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$state" = 1 ]; then
            [ "$line" = "$QMI_A_NEG_END" ] || continue
            state=2
        fi
        case $line in *"$QMI_SCAN_PATTERN"*) continue ;; esac
        case $line in
        "$QMI_A_NEG_START")
            cat "$QMI_EDITS/call.sh"
            state=1
            continue
            ;;
        "$QMI_A_FUNCS") cat "$QMI_EDITS/functions.sh" ;;
        "$QMI_A_REGISTER") printf '%s\n' "$QMI_N_REGISTER" ;;
        "$QMI_A_464") line=$QMI_N_464 ;;
        "$QMI_A_V6")
            line=$QMI_N_V6
            seen_v6=1
            ;;
        "$QMI_A_V6LOAD") line=$QMI_N_V6LOAD ;;
        "$QMI_A_V4") [ "$seen_v6" != 1 ] || line=$QMI_N_V4 ;;
        esac
        printf '%s\n' "$line"
    done <"$in" >"$tmp"
    mv -f "$tmp" "$out"
}

# qmi_fetch_package IB WORKDIR: the uqmi .apk exactly as the ImageBuilder's apk resolves it from its
# own repositories file and keys (the index is signature checked, and the index holds the package
# hash), into WORKDIR/pkg; echoes its path
qmi_fetch_package() {
    local ib=$1 work=$2 arch pkg
    local apk=$ib/staging_dir/host/bin/apk
    arch=$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\(.*\)"$/\1/p' "$ib/.config")
    [ -n "$arch" ] || die "no CONFIG_TARGET_ARCH_PACKAGES in $ib/.config"
    mkdir -p "$work/root" "$work/cache" "$work/pkg"
    local a=("$apk" --root "$work/root" --keys-dir "$ib/keys" --repositories-file "$ib/repositories"
        --cache-dir "$work/cache" --arch "$arch")
    "${a[@]}" add --initdb --usermode >/dev/null 2>&1 || die "apk could not set up $work/root"
    "${a[@]}" update >"$work/apk.log" 2>&1 ||
        die "cannot read the package feeds of $ib/repositories (network?): $(tail -n 3 "$work/apk.log")"
    "${a[@]}" fetch --output "$work/pkg" uqmi >"$work/apk.log" 2>&1 ||
        die "cannot fetch the uqmi package (network?): $(tail -n 3 "$work/apk.log")"
    pkg=$(compgen -G "$work/pkg/uqmi-*.apk" | head -n1) || true
    [ -n "$pkg" ] || die "apk fetched no uqmi-*.apk into $work/pkg"
    echo "$pkg"
}

# qmi_derive IB OUT_ROOT WORKDIR: OUT_ROOT/lib/netifd/proto/qmi.sh = the package's file with the
# edits of R12d. Stops, with no file written, when the file is not the reviewed one, an anchor is
# not there exactly once or the result fails sh -n.
qmi_derive() {
    local ib=$1 root=$2 work=$3 pkg stock out
    # explicit: errexit is off inside a command substitution, and qmi_fetch_package already said why
    pkg=$(qmi_fetch_package "$ib" "$work") || exit 1
    mkdir -p "$work/ext"
    "$ib/staging_dir/host/bin/apk" extract --allow-untrusted --destination "$work/ext" "$pkg" \
        >/dev/null 2>&1 || die "cannot unpack ${pkg##*/}"
    stock=$work/ext/$QMI_SH_REL
    [ -f "$stock" ] || die "${pkg##*/} has no /$QMI_SH_REL"
    out=$work/qmi.sh.derived
    qmi_transform "$stock" "$out" "${pkg##*/}"
    qmi_sh_n "$out" || die "the derived /$QMI_SH_REL of ${pkg##*/} fails sh -n"
    # the overlay's directories are 0755 like render.py's set_dir_modes makes them (cp -p in the IB)
    # errexit is off here too (the callers run this in a command substitution), hence the die
    { mkdir -p "$root/$(dirname "$QMI_SH_REL")" &&
        chmod 0755 "$root/lib" "$root/lib/netifd" "$root/lib/netifd/proto" &&
        install -m 0755 "$out" "$root/$QMI_SH_REL"; } || die "cannot write /$QMI_SH_REL into $root"
    echo "${pkg##*/}"
}

# qmi_verify IB: after `make image`, the ImageBuilder's final rootfs holds the pristine package file
# (root.orig-*, copied before FILES) with the edits of R12d, byte for byte and with its mode (R12f)
qmi_verify() {
    local ib=$1 orig final checked=0 want
    want=$(mktemp) || die "cannot make a temporary file"
    for orig in "$ib"/build_dir/target-*/root.orig-*; do
        [ -d "$orig" ] || continue
        final=${orig/root.orig-/root-}
        qmi_transform "$orig/$QMI_SH_REL" "$want" "the package's file"
        cmp -s "$want" "$final/$QMI_SH_REL" ||
            die "the image's /$QMI_SH_REL is not the package's file with the edits of R12d" \
                "(the feed changed during the build?): build again"
        [ "$(stat -c %a "$orig/$QMI_SH_REL")" = "$(stat -c %a "$final/$QMI_SH_REL")" ] ||
            die "the image's /$QMI_SH_REL does not have the package file's mode"
        checked=1
    done
    rm -f -- "$want"
    [ "$checked" = 1 ] || die "no root.orig-* in $ib/build_dir to check /$QMI_SH_REL against"
}
