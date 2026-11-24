# shellcheck shell=bash disable=SC2016  # the edited lines hold a literal $
# Sourced by build.sh and tests/vm/build-image.sh (SPEC R14b, R14c, D195): derives the image's
# /usr/bin/watchcat.sh and /etc/init.d/watchcat from the `watchcat` package that the ImageBuilder
# installs, and checks after the build that the image holds exactly those files with the same edits.
# The repository keeps no copy of either file (they are GPL-2.0, the repository is MIT): only the
# anchors below, the few lines they get, and the hook itself (src/files/usr/lib/lw/watchcat-family.sh,
# lonewrt's own file). Every upstream line, copyright notices included, stays. The caller sets
# LW_ROOTFS, has a die(), and has sourced qmi-handler.sh first (lw_pin, qmi_sh_n).

WC_SH_REL=usr/bin/watchcat.sh
WC_INIT_REL=etc/init.d/watchcat
# R14c: the sha256 of the two stock files the edits were reviewed against (package watchcat 1-r25,
# OpenWrt 25.12.6). LW_WATCHCAT_SHA256 and LW_WATCHCAT_INIT_SHA256 are for the tests only (lw_pin,
# R12g, D205): outside the test suite a build with either set stops.
WC_STOCK_SHA256=$(lw_pin LW_WATCHCAT_SHA256 6a586873d27f5f538453dd4bb90a833ada7fea8a8908a00c0bc2e53c4779ad5e) || exit 1
WC_INIT_STOCK_SHA256=$(lw_pin LW_WATCHCAT_INIT_SHA256 5468cca075d24028997b393a206ec6e73cf2dfd22741f611be612e478789fd10) || exit 1

# The worker script, three edits, each anchor a whole line found exactly once. The hook is chosen by
# the environment variable that only the init script sets, and only for an entry with the option
# lw_family_check (R14b): any other entry runs the stock lines unchanged.
# (1) the hook's functions are loaded after the stock libraries
WC_A_LIB='. /lib/functions/network.sh'
WC_N_LIB='[ -z "$LW_WATCHCAT_FAMILY" ] || . /usr/lib/lw/watchcat-family.sh'
# (2) the stock loop over the hosts, which pings every host and has no bound, gets none, so the
# loop runs no pass; the anchor is the line in watchcat_monitor_network alone (restart_iface and
# run_script), not watchcat_ping (the reboot mode)
WC_A_HOSTS=$'\t[ "$mm_iface_name" = "null" ] && mm_iface_name=""'
WC_N_HOSTS=$'\t[ -z "$LW_WATCHCAT_FAMILY" ] || ping_hosts=""'
# (3) the family check runs in its place, before the stock test of the silence timer
WC_A_TIMER=$'\t\t[ "$((time_now - time_lastcheck_withinternet))" -ge "$failure_period" ] && {'
WC_N_TIMER=$'\t\t[ -z "$LW_WATCHCAT_FAMILY" ] || lw_wc_round'
# The init script, two edits: the option is read next to the stock options, and for restart_iface the
# instance gets the variable
WC_A_OPT=$'\tconfig_get script "$1" script'
WC_N_OPT=$'\tconfig_get_bool lw_family_check "$1" lw_family_check "0"'
WC_A_ENV=$'\t\t\t"$addressfamily" "" "$reset_failure_timer"'
WC_N_ENV=$'\t\t[ "$lw_family_check" != 1 ] || procd_set_param env LW_WATCHCAT_FAMILY=1'

# wc_check_pin FILE NAME LABEL PIN: FILE has the reviewed sha256, else stop (R14c)
wc_check_pin() {
    local sum
    sum=$(sha256sum "$1" | cut -d' ' -f1)
    [ "$sum" = "$4" ] ||
        die "$3 of $2 has sha256 $sum, the edits were reviewed against $4" \
            "(SPEC R14c): read the new file, change the edits and the pin (docs/development.md)"
}

# wc_expect_once FILE NAME LABEL LINE: LINE is a whole line of FILE exactly once, else stop
wc_expect_once() {
    local n
    n=$(grep -cxF -e "$4" "$1" || true)
    [ "$n" = 1 ] ||
        die "$(basename "$1") of $2 has $n lines equal to the anchor $3, expected exactly 1" \
            "(SPEC R14c): read the new file and change the edits (docs/development.md)"
}

# wc_edit IN OUT ANCHOR NEW before|after: OUT = IN with the line NEW put before or after the line
# ANCHOR; every other line is IN's, byte for byte
wc_edit() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "$3" ] && [ "$5" = before ]; then printf '%s\n' "$4"; fi
        printf '%s\n' "$line"
        if [ "$line" = "$3" ] && [ "$5" = after ]; then printf '%s\n' "$4"; fi
    done <"$1" >"$2"
}

# wc_transform STOCK_SH STOCK_INIT OUT_SH OUT_INIT NAME: the two files with the edits. Stops, with
# nothing written, when a file has another sha256 than the reviewed one or an anchor is not there
# exactly once.
wc_transform() {
    local sh=$1 init=$2 out_sh=$3 out_init=$4 name=$5 t1 t2
    wc_check_pin "$sh" "$name" "/$WC_SH_REL" "$WC_STOCK_SHA256"
    wc_check_pin "$init" "$name" "/$WC_INIT_REL" "$WC_INIT_STOCK_SHA256"
    wc_expect_once "$sh" "$name" "stock libraries" "$WC_A_LIB"
    wc_expect_once "$sh" "$name" "host list of the monitor" "$WC_A_HOSTS"
    wc_expect_once "$sh" "$name" "silence timer test" "$WC_A_TIMER"
    wc_expect_once "$init" "$name" "script option" "$WC_A_OPT"
    wc_expect_once "$init" "$name" "restart_iface command" "$WC_A_ENV"
    t1=$(mktemp "$out_sh.XXXXXX") || die "cannot write $out_sh"
    t2=$(mktemp "$out_init.XXXXXX") || die "cannot write $out_init"
    {
        wc_edit "$sh" "$t1.a" "$WC_A_LIB" "$WC_N_LIB" after &&
            wc_edit "$t1.a" "$t1.b" "$WC_A_HOSTS" "$WC_N_HOSTS" after &&
            wc_edit "$t1.b" "$t1" "$WC_A_TIMER" "$WC_N_TIMER" before &&
            wc_edit "$init" "$t2.a" "$WC_A_OPT" "$WC_N_OPT" after &&
            wc_edit "$t2.a" "$t2" "$WC_A_ENV" "$WC_N_ENV" after
    } || die "cannot derive $name"
    rm -f -- "$t1.a" "$t1.b" "$t2.a"
    mv -f "$t1" "$out_sh"
    mv -f "$t2" "$out_init"
}

# wc_fetch_package IB WORKDIR: the watchcat .apk exactly as the ImageBuilder's apk resolves it from
# its own repositories file and keys, into WORKDIR/pkg; echoes its path
wc_fetch_package() {
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
    "${a[@]}" fetch --output "$work/pkg" watchcat >"$work/apk.log" 2>&1 ||
        die "cannot fetch the watchcat package (network?): $(tail -n 3 "$work/apk.log")"
    pkg=$(compgen -G "$work/pkg/watchcat-[0-9]*.apk" | head -n1) || true
    [ -n "$pkg" ] || die "apk fetched no watchcat-*.apk into $work/pkg"
    echo "$pkg"
}

# wc_derive IB OUT_ROOT WORKDIR: OUT_ROOT/usr/bin/watchcat.sh and OUT_ROOT/etc/init.d/watchcat = the
# package's files with the edits of R14b. Stops, with no file written, when a file is not the
# reviewed one, an anchor is not there exactly once or a result fails sh -n.
wc_derive() {
    local ib=$1 root=$2 work=$3 pkg d
    pkg=$(wc_fetch_package "$ib" "$work") || exit 1
    mkdir -p "$work/ext"
    "$ib/staging_dir/host/bin/apk" extract --allow-untrusted --destination "$work/ext" "$pkg" \
        >/dev/null 2>&1 || die "cannot unpack ${pkg##*/}"
    [ -f "$work/ext/$WC_SH_REL" ] || die "${pkg##*/} has no /$WC_SH_REL"
    [ -f "$work/ext/$WC_INIT_REL" ] || die "${pkg##*/} has no /$WC_INIT_REL"
    wc_transform "$work/ext/$WC_SH_REL" "$work/ext/$WC_INIT_REL" "$work/watchcat.sh.derived" \
        "$work/watchcat.init.derived" "${pkg##*/}"
    qmi_sh_n "$work/watchcat.sh.derived" || die "the derived /$WC_SH_REL of ${pkg##*/} fails sh -n"
    qmi_sh_n "$work/watchcat.init.derived" || die "the derived /$WC_INIT_REL of ${pkg##*/} fails sh -n"
    # the overlay's directories are 0755 like render.py's set_dir_modes makes them
    for d in usr usr/bin etc etc/init.d; do
        [ -d "$root/$d" ] || { mkdir -p "$root/$d" && chmod 0755 "$root/$d"; } || die "cannot make $root/$d"
    done
    { install -m 0755 "$work/watchcat.sh.derived" "$root/$WC_SH_REL" &&
        install -m 0755 "$work/watchcat.init.derived" "$root/$WC_INIT_REL"; } ||
        die "cannot write /$WC_SH_REL and /$WC_INIT_REL into $root"
    echo "${pkg##*/}"
}

# wc_verify IB: after `make image`, the ImageBuilder's final rootfs holds the pristine package files
# (root.orig-*, copied before FILES) with the edits of R14b, byte for byte and with their modes
wc_verify() {
    local ib=$1 orig final checked=0 want_sh want_init f
    want_sh=$(mktemp) || die "cannot make a temporary file"
    want_init=$(mktemp) || die "cannot make a temporary file"
    for orig in "$ib"/build_dir/target-*/root.orig-*; do
        [ -d "$orig" ] || continue
        final=${orig/root.orig-/root-}
        wc_transform "$orig/$WC_SH_REL" "$orig/$WC_INIT_REL" "$want_sh" "$want_init" "the package's files"
        cmp -s "$want_sh" "$final/$WC_SH_REL" ||
            die "the image's /$WC_SH_REL is not the package's file with the edits of R14b" \
                "(the feed changed during the build?): build again"
        cmp -s "$want_init" "$final/$WC_INIT_REL" ||
            die "the image's /$WC_INIT_REL is not the package's file with the edits of R14b" \
                "(the feed changed during the build?): build again"
        for f in "$WC_SH_REL" "$WC_INIT_REL"; do
            [ "$(stat -c %a "$orig/$f")" = "$(stat -c %a "$final/$f")" ] ||
                die "the image's /$f does not have the package file's mode"
        done
        checked=1
    done
    rm -f -- "$want_sh" "$want_init"
    [ "$checked" = 1 ] || die "no root.orig-* in $ib/build_dir to check /$WC_SH_REL against"
}
