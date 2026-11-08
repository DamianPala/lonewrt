#!/usr/bin/env bash
# Download what the build and the tests need into $LW_WORK (default: work/ next to this script).
#
#   ./fetch-deps.sh [--quiet] [GROUP...]
#
# Groups (deps.lst has the files, their sha256 and their sources):
#   ib      ImageBuilder for the router, about 480 MB            (build.sh)
#   extra   .apk files from outside the official feeds           (build.sh, tests/vm)
#   gawk    GNU awk for the ImageBuilder, only if the host has none
#   rootfs  x86_64 rootfs for tests/run-all.sh, unpacked to dl/x86/rootfs
#   vm      x86_64 ImageBuilder for tests/vm, about 40 MB, in $LWVM_WORK (default $LW_WORK/vm)
#   rescue  stock images for a recovery over the serial console (not in the default set)
# Default: ib extra gawk rootfs vm.
#
# A file that is already there is checked against its sha256 and left alone; a wrong sum stops the
# script (delete the file to fetch it again). A download is checked before it gets its final name.
set -euo pipefail

FW="$(cd "$(dirname "$0")" && pwd)"
LW_WORK=$(realpath -m -s "${LW_WORK:-$FW/work}")
VMWORK=$(realpath -m -s "${LWVM_WORK:-$LW_WORK/vm}")
LIST=${LW_DEPS_LIST:-$FW/deps.lst}
QUIET=0
PRESENT=0
FETCHED=0

die() {
    echo "fetch-deps: error: $*" >&2
    exit 1
}

say() {
    echo "fetch-deps: $*" >&2
}

# local_path PATH: where a path of deps.lst lands
local_path() {
    case $1 in
    vm/*) echo "$VMWORK/${1#vm/}" ;;
    *) echo "$LW_WORK/$1" ;;
    esac
}

# fetch_file SHA256 PATH URL: present and right, or downloaded and checked
fetch_file() {
    local sum=$1 target url=$3 have
    target=$(local_path "$2")
    if [ -f "$target" ]; then
        have=$(sha256sum "$target" | cut -d' ' -f1)
        [ "$have" = "$sum" ] ||
            die "sha256 mismatch: $target is $have, expected $sum (delete it to fetch it again)"
        PRESENT=$((PRESENT + 1))
        [ "$QUIET" = 1 ] || say "present  $2"
        return 0
    fi
    mkdir -p "$(dirname "$target")"
    say "fetching $2 from $url"
    curl --fail --location --silent --show-error --retry 3 --retry-all-errors --connect-timeout 20 \
        --output "$target.part" "$url" || {
        rm -f -- "$target.part"
        die "download failed: $url"
    }
    have=$(sha256sum "$target.part" | cut -d' ' -f1)
    if [ "$have" != "$sum" ]; then
        rm -f -- "$target.part"
        die "sha256 mismatch for $url: got $have, expected $sum"
    fi
    mv -- "$target.part" "$target"
    FETCHED=$((FETCHED + 1))
}

# fetch_group GROUP: every line of deps.lst for the group
fetch_group() {
    local group sum path url found=0
    while read -r group sum path url; do
        case $group in '' | '#'*) continue ;; esac
        [ "$group" = "$1" ] || continue
        found=1
        fetch_file "$sum" "$path" "$url"
    done <"$LIST"
    [ "$found" = 1 ] || die "no files for group '$1' in $LIST"
}

# host_has_gnu_awk: ImageBuilder calls `awk`; mawk and busybox awk do not do
host_has_gnu_awk() {
    awk --version 2>&1 | grep -q 'GNU Awk'
}

# write_wrapper NAME TARGET [LIBDIR]: tools/bin/NAME runs TARGET, written only when it differs
write_wrapper() {
    local file=$LW_WORK/tools/bin/$1 want
    if [ -n "${3:-}" ]; then
        want=$(printf '#!/bin/sh\nLD_LIBRARY_PATH=%s exec %s "$@"\n' "$3" "$2")
    else
        want=$(printf '#!/bin/sh\nexec %s "$@"\n' "$2")
    fi
    if [ -x "$file" ] && [ "$(cat "$file")" = "$want" ]; then return 0; fi
    mkdir -p "$LW_WORK/tools/bin"
    printf '%s\n' "$want" >"$file.part"
    chmod 755 "$file.part"
    mv -- "$file.part" "$file"
    say "wrote $file"
}

# install_gawk: a gawk the ImageBuilder finds first on PATH (build.sh puts tools/bin there)
install_gawk() {
    local root=$LW_WORK/tools/root host
    if host_has_gnu_awk; then
        say "gawk: the host's awk is GNU awk, nothing to fetch"
        return 0
    fi
    if host=$(command -v gawk); then
        say "gawk: using $host"
        write_wrapper awk "$host"
        write_wrapper gawk "$host"
        return 0
    fi
    command -v dpkg-deb >/dev/null || die "gawk: install gawk (e.g. sudo apt install gawk) or dpkg-deb"
    fetch_group gawk
    if [ ! -x "$root/usr/bin/gawk" ]; then
        local deb
        for deb in "$LW_WORK"/tools/deb/*.deb; do
            dpkg-deb -x "$deb" "$root"
        done
        say "gawk: unpacked into $root"
    fi
    write_wrapper awk "$root/usr/bin/gawk" "$root/usr/lib/x86_64-linux-gnu"
    write_wrapper gawk "$root/usr/bin/gawk" "$root/usr/lib/x86_64-linux-gnu"
}

# apk_in ROOT ARG...: the rootfs's own apk, run through its musl loader, so no apk and no root
# are needed on the host
apk_in() {
    local root=$1
    shift
    "$root/lib/ld-musl-x86_64.so.1" --library-path "$root/lib:$root/usr/lib" \
        "$root/usr/bin/apk" "$@"
}

# unpack_rootfs: tests/rootfs/run.sh needs the rootfs plus the coreutils `timeout` the router has
unpack_rootfs() {
    local dir=$LW_WORK/dl/x86 root=$LW_WORK/dl/x86/rootfs tmp
    if [ -x "$root/bin/busybox" ] && [ -e "$root/usr/libexec/timeout-coreutils" ]; then
        [ "$QUIET" = 1 ] || say "present  dl/x86/rootfs"
        return 0
    fi
    [ ! -e "$root" ] || die "$root exists but is incomplete: delete it and run again"
    tmp=$dir/rootfs.part
    rm -rf -- "$tmp"
    mkdir -p "$tmp"
    tar -xzf "$dir/openwrt-25.12.6-x86-64-rootfs.tar.gz" -C "$tmp"
    apk_in "$tmp" add --root "$tmp" --allow-untrusted --no-network --no-scripts --no-cache \
        --no-logfile "$dir/apk/coreutils-9.9-r2.apk" "$dir/apk/coreutils-timeout-9.9-r2.apk" >&2
    # the package's post-install script makes this link, and --no-scripts skips it
    ln -s ../libexec/timeout-coreutils "$tmp/usr/bin/timeout"
    mv -- "$tmp" "$root"
    FETCHED=$((FETCHED + 1))
    say "unpacked dl/x86/rootfs"
}

usage() {
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

main() {
    local groups=() group
    while [ $# -gt 0 ]; do
        case $1 in
        --quiet) QUIET=1 ;;
        -h | --help) usage ;;
        -*) die "unknown option $1" ;;
        *) groups+=("$1") ;;
        esac
        shift
    done
    [ ${#groups[@]} -gt 0 ] || groups=(ib extra gawk rootfs vm)
    command -v curl >/dev/null || die "curl is required"
    [ -f "$LIST" ] || die "missing $LIST"
    for group in "${groups[@]}"; do
        case $group in
        gawk) install_gawk ;;
        rootfs)
            fetch_group rootfs
            unpack_rootfs
            ;;
        ib | extra | vm | rescue) fetch_group "$group" ;;
        *) die "unknown group '$group' (ib extra gawk rootfs vm rescue)" ;;
        esac
    done
    say "done: $PRESENT present, $FETCHED fetched (work dir $LW_WORK)"
}

main "$@"
