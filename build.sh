#!/usr/bin/env bash
# Build a sysupgrade image for the ZTE MF289F from one profile with the official OpenWrt 25.12.6
# ImageBuilder (SPEC R1 to R6, R33). Every profile builds from the same sources; profiles/generic.conf
# is the secret-free template.
#
#   ./build.sh <name>                     profiles/<name>.conf -> image/<name>-sysupgrade.bin,
#                                         image/<name>.manifest, image/<name>-passwords.txt (when
#                                         passwords were drawn or reused)
#   ./build.sh --render-only <name> <dir> only the rendered overlay (ImageBuilder FILES) into <dir>,
#                                         a drawn password card next to it as <dir>-passwords.txt
#
# Environment: LW_WORK (ImageBuilder and downloads, default work/ next to this script; fill it with
# ./fetch-deps.sh), LW_ROOTFS (OpenWrt rootfs whose busybox runs the sh -n check). Tests also set
# LW_PROFILES, LW_SRC and LW_IMAGE to work on copies.
set -euo pipefail

FW="$(cd "$(dirname "$0")" && pwd)"
LW_WORK=${LW_WORK:-$FW/work}
LW_ROOTFS=${LW_ROOTFS:-$LW_WORK/dl/x86/rootfs}
PROFILES=${LW_PROFILES:-$FW/profiles}
SRC=${LW_SRC:-$FW/src}
IMAGE=${LW_IMAGE:-$FW/image}
IB=$LW_WORK/ib
IB_TAR=$LW_WORK/dl/openwrt-imagebuilder-25.12.6-ipq40xx-generic.Linux-x86_64.tar.zst

# The "Included" table of packages.md (SPEC R2); the device profile adds the default set.
PACKAGES=(
    luci luci-ssl luci-proto-qmi luci-proto-wireguard wireguard-tools
    watchcat luci-app-watchcat
    sms-tool comgt luci-app-sms-tool-js
    modemdata luci-app-modemdata modemband luci-app-modemband
    nlbwmon luci-app-nlbwmon
    wifischedule luci-app-wifischedule
    coreutils-timeout coreutils-stty
    speedtestcpp
)

# Scratch directory of this run: the rendered overlay with the profile's secrets, ImageBuilder output
TMP=
# Profile whose ImageBuilder leftovers still need scrubbing when the build is interrupted
SCRUB=
cleanup() {
    if [ -n "$SCRUB" ]; then scrub_imagebuilder "$SCRUB"; fi
    if [ -n "$TMP" ]; then rm -rf -- "$TMP"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

die() {
    echo "build: error: $*" >&2
    exit 1
}

usage() {
    echo "usage: $0 <profile> | $0 --render-only <profile> <dir>" >&2
    exit 2
}

# need CMD...: stop before any work when a host program is missing (README, "Hardware")
need() {
    local c
    for c; do command -v "$c" >/dev/null || die "$c is required on the build host (see README, Hardware)"; done
}

check_name() {
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die "profile name '$1': use letters, digits, - and _"
    [ -f "$PROFILES/$1.conf" ] || die "no profile $PROFILES/$1.conf"
}

# render NAME OUT CARD_OUT: profile checks (R3), passwords (R33), overlay, sh -n (R6)
render() {
    python3 -I "$SRC/render.py" --name "$1" --profiles "$PROFILES" --src "$SRC" --out "$2" \
        --card-in "$IMAGE/$1-passwords.txt" --card-out "$3" --rootfs "$LW_ROOTFS"
}

render_only() {
    local name=$1 dir=${2%/} parent
    check_name "$name"
    if [ -e "$dir" ] && [ -n "$(ls -A "$dir")" ]; then
        die "$dir is not empty; pass a new or empty directory"
    fi
    parent=$(dirname "$dir")
    mkdir -p "$parent"
    TMP=$(mktemp -d "$parent/.render-$name.XXXXXX")
    render "$name" "$TMP/files" "$TMP/passwords.txt"
    if [ -d "$dir" ]; then rmdir "$dir"; fi
    mv "$TMP/files" "$dir"
    if [ -f "$TMP/passwords.txt" ]; then
        mv "$TMP/passwords.txt" "$dir-passwords.txt"
    fi
    echo "build: rendered overlay for profile $name in $dir" >&2
}

prepare_imagebuilder() {
    compgen -G "$LW_WORK/dl/extra/*.apk" >/dev/null ||
        die "no .apk files in $LW_WORK/dl/extra: run ./fetch-deps.sh"
    if [ ! -d "$IB" ]; then
        [ -f "$IB_TAR" ] || die "no ImageBuilder archive $IB_TAR: run ./fetch-deps.sh"
        mkdir -p "$IB"
        tar --zstd -xf "$IB_TAR" -C "$IB" --strip-components=1
    fi
}

# scrub_imagebuilder NAME: ImageBuilder keeps the last profile's rootfs and image in build_dir,
# readable by all; with a full profile that is a copy of every secret (SPEC D15). The next build
# recreates all of it, so removing it costs nothing.
scrub_imagebuilder() {
    local target
    for target in "$IB"/build_dir/target-*; do
        [ -d "$target" ] || continue
        # root.orig-* is the pristine package rootfs ImageBuilder copies from; it holds no profile data
        rm -rf -- "$target"/root-* "$target"/linux-*/root.squashfs \
            "$target"/linux-*/tmp/*-"$1"-* "$target"/json_info_files/*-"$1"-*
    done
}

# run_imagebuilder NAME FILES BIN_DIR LOG: one build at a time per ImageBuilder tree; the lock
# (fd 9 on the tree) covers the package copy, make and the scrub
run_imagebuilder() {
    local rc=0
    exec 9<"$IB"
    flock 9
    SCRUB=$1
    # Packages from outside the official feeds (packages.md)
    cp "$LW_WORK"/dl/extra/*.apk "$IB/packages/"
    # ImageBuilder wants GNU awk; the laptop only has mawk, so a locally extracted gawk goes first
    PATH=$LW_WORK/tools/bin:$PATH make -C "$IB" image \
        PROFILE=zte_mf289f \
        PACKAGES="${PACKAGES[*]}" \
        FILES="$2" \
        EXTRA_IMAGE_NAME="$1" \
        BIN_DIR="$3" >"$4" 2>&1 || rc=$?
    scrub_imagebuilder "$1"
    SCRUB=
    exec 9<&-
    if [ "$rc" -ne 0 ]; then
        tail -n 40 "$4" >&2
        die "ImageBuilder failed for profile $1"
    fi
}

# publish SOURCE TARGET: rename into image/ only after everything succeeded (SPEC R3, R6)
publish() {
    cp "$1" "$2.tmp"
    mv -f "$2.tmp" "$2"
}

build() {
    local name=$1 bin manifest
    check_name "$name"
    mkdir -p "$IMAGE"
    TMP=$(mktemp -d "$IMAGE/.build-$name.XXXXXX")
    render "$name" "$TMP/files" "$TMP/passwords.txt"
    prepare_imagebuilder
    run_imagebuilder "$name" "$TMP/files" "$TMP/bin" "$TMP/make.log"

    bin=$(compgen -G "$TMP/bin/*-$name-*-squashfs-sysupgrade.bin" | head -n1) || true
    manifest=$(compgen -G "$TMP/bin/*-$name-*.manifest" | head -n1) || true
    [ -n "$bin" ] && [ -n "$manifest" ] || die "ImageBuilder produced no sysupgrade image or manifest"

    publish "$manifest" "$IMAGE/$name.manifest"
    # An unchanged card keeps its file, so a second build does not touch it (SPEC R33)
    if [ -f "$TMP/passwords.txt" ] && ! cmp -s "$TMP/passwords.txt" "$IMAGE/$name-passwords.txt"; then
        publish "$TMP/passwords.txt" "$IMAGE/$name-passwords.txt"
    fi
    # A profile image carries its secrets (SPEC D15): readable by the owner only
    chmod 0600 "$bin"
    publish "$bin" "$IMAGE/$name-sysupgrade.bin"
    echo "build: $IMAGE/$name-sysupgrade.bin ($(stat -c %s "$IMAGE/$name-sysupgrade.bin") bytes)" >&2
    sha256sum "$IMAGE/$name-sysupgrade.bin"
}

case ${1:-} in
--render-only)
    [ $# -eq 3 ] || usage
    need python3 openssl
    render_only "$2" "$3"
    ;;
"" | -*) usage ;;
*)
    [ $# -eq 1 ] || usage
    need python3 openssl tar zstd make flock
    build "$1"
    ;;
esac
