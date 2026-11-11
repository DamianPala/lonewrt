# shellcheck shell=bash
# Sourced by build.sh and tests/vm/build-image.sh (SPEC R12d, D82): derives the image's
# /lib/netifd/proto/qmi.sh from the `uqmi` package that the ImageBuilder installs, and checks after
# the build that the image holds exactly that file. The repository keeps no copy of the file (it is
# GPL-2.0, the repository is MIT). The caller sets LW_ROOTFS and has a die().

QMI_SH_REL=lib/netifd/proto/qmi.sh
# The one line the image drops: qmi.sh's call that scans the network for 26 s after the mode set
QMI_SCAN_PATTERN=--network-scan

# qmi_count_scan FILE: how many lines of FILE hold the scan call
qmi_count_scan() {
    grep -cF -e "$QMI_SCAN_PATTERN" "$1" || true
}

# qmi_strip_scan FILE: FILE without its scan line(s), on stdout
qmi_strip_scan() {
    grep -vF -e "$QMI_SCAN_PATTERN" "$1" || true
}

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

# qmi_derive IB OUT_ROOT WORKDIR: OUT_ROOT/lib/netifd/proto/qmi.sh = the package's file minus its
# scan line. Stops, with no file written, when the line is not there exactly once or the result
# fails sh -n.
qmi_derive() {
    local ib=$1 root=$2 work=$3 pkg stock n out
    # explicit: errexit is off inside a command substitution, and qmi_fetch_package already said why
    pkg=$(qmi_fetch_package "$ib" "$work") || exit 1
    mkdir -p "$work/ext"
    "$ib/staging_dir/host/bin/apk" extract --allow-untrusted --destination "$work/ext" "$pkg" \
        >/dev/null 2>&1 || die "cannot unpack ${pkg##*/}"
    stock=$work/ext/$QMI_SH_REL
    [ -f "$stock" ] || die "${pkg##*/} has no /$QMI_SH_REL"
    n=$(qmi_count_scan "$stock")
    if [ "$n" != 1 ]; then
        die "/$QMI_SH_REL of ${pkg##*/} has $n lines with $QMI_SCAN_PATTERN, expected exactly 1" \
            "(SPEC D82): read the new file and measure ifup again (docs/development.md)"
    fi
    out=$work/qmi.sh.derived
    qmi_strip_scan "$stock" >"$out"
    qmi_sh_n "$out" || die "the derived /$QMI_SH_REL of ${pkg##*/} fails sh -n"
    # the overlay's directories are 0755 like render.py's set_dir_modes makes them (cp -p in the IB)
    # errexit is off here too (the callers run this in a command substitution), hence the die
    { mkdir -p "$root/$(dirname "$QMI_SH_REL")" &&
        chmod 0755 "$root/lib" "$root/lib/netifd" "$root/lib/netifd/proto" &&
        install -m 0755 "$out" "$root/$QMI_SH_REL"; } || die "cannot write /$QMI_SH_REL into $root"
    echo "${pkg##*/}"
}

# qmi_verify IB: after `make image`, the ImageBuilder's final rootfs holds the pristine package file
# (root.orig-*, copied before FILES) minus its one scan line, byte for byte
qmi_verify() {
    local ib=$1 orig final n checked=0
    for orig in "$ib"/build_dir/target-*/root.orig-*; do
        [ -d "$orig" ] || continue
        final=${orig/root.orig-/root-}
        n=$(qmi_count_scan "$orig/$QMI_SH_REL")
        [ "$n" = 1 ] || die "the package's /$QMI_SH_REL has $n lines with $QMI_SCAN_PATTERN, expected 1"
        cmp -s <(qmi_strip_scan "$orig/$QMI_SH_REL") "$final/$QMI_SH_REL" ||
            die "the image's /$QMI_SH_REL is not the package's file minus its scan line" \
                "(the feed changed during the build?): build again"
        [ "$(stat -c %a "$orig/$QMI_SH_REL")" = "$(stat -c %a "$final/$QMI_SH_REL")" ] ||
            die "the image's /$QMI_SH_REL does not have the package file's mode"
        checked=1
    done
    [ "$checked" = 1 ] || die "no root.orig-* in $ib/build_dir to check /$QMI_SH_REL against"
}
