#!/usr/bin/env bash
# Build the x86_64 VM image for the bench: official OpenWrt 25.12.6 x86/64 ImageBuilder, the router
# image's package list (as far as x86 has it), a rendered rootfs overlay plus the VM-only overlay.
# Usage: tests/vm/build-image.sh [OVERLAY_DIR]
#   OVERLAY_DIR  a rendered overlay (what ImageBuilder gets as FILES); default: what
#                `build.sh --render-only generic DIR` writes.
# Prints the image directory (disk.img, lan_ip, overlay.txt, manifest) as the last line. Images are
# cached by a hash of their inputs, so an unchanged overlay costs nothing.
set -euo pipefail

VMDIR="$(cd "$(dirname "$0")" && pwd)"
FW="$(cd "$VMDIR/../.." && pwd)"
LW_WORK=${LW_WORK:-$FW/work}
VMWORK=${LWVM_WORK:-$LW_WORK/vm}
IB_TAR=$VMWORK/dl/openwrt-imagebuilder-25.12.6-x86-64.Linux-x86_64.tar.zst
IB=$VMWORK/ib
# shellcheck disable=SC2034  # read by install_extra_packages in pinned-packages.sh
DEPS=${LW_DEPS_LIST:-$FW/deps.lst}
# shellcheck source=pinned-packages.sh
source "$FW/pinned-packages.sh"
# shellcheck source=qmi-handler.sh
source "$FW/qmi-handler.sh"
LW_ROOTFS=${LW_ROOTFS:-$LW_WORK/dl/x86/rootfs}
# ImageBuilder wants GNU awk; the laptop only has mawk
export PATH=$LW_WORK/tools/bin:$PATH

# packages.md "Included" plus the MF289F device defaults that exist for x86_64 too
PACKAGES=(
    uqmi kmod-usb-net-qmi-wwan kmod-usb-serial-option wpad-basic-mbedtls
    luci luci-ssl luci-proto-qmi luci-proto-wireguard wireguard-tools
    watchcat luci-app-watchcat
    sms-tool comgt luci-app-sms-tool-js
    modemdata luci-app-modemdata modemband luci-app-modemband
    nlbwmon luci-app-nlbwmon
    wifischedule luci-app-wifischedule
    coreutils-timeout coreutils-stty
)

log() { echo "build-image: $*" >&2; }
die() { log "$*"; exit 1; }

# fetch-deps.sh downloads what is missing and checks the sha256 of what is there
ensure_ib() {
    "$FW/fetch-deps.sh" --quiet extra gawk vm >&2
    [ -f "$IB/Makefile" ] && return 0
    mkdir -p "$IB"
    tar --zstd -xf "$IB_TAR" -C "$IB" --strip-components=1
}

# Only what the bench needs: squashfs combined BIOS image (overlay + firstboot like the router), no
# GRUB menu delay. These switch image types off; packages and kernel stay as released.
tune_ib() {
    sed -i \
        -e 's/^CONFIG_TARGET_ROOTFS_EXT4FS=y/# CONFIG_TARGET_ROOTFS_EXT4FS is not set/' \
        -e 's/^CONFIG_TARGET_ROOTFS_TARGZ=y/# CONFIG_TARGET_ROOTFS_TARGZ is not set/' \
        -e 's/^CONFIG_GRUB_EFI_IMAGES=y/# CONFIG_GRUB_EFI_IMAGES is not set/' \
        -e 's/^CONFIG_GRUB_TIMEOUT=.*/CONFIG_GRUB_TIMEOUT="0"/' \
        "$IB/.config"
    # the same checked copy as build.sh: only the pins of deps.lst, each with its sha256 (R2a)
    install_extra_packages "$IB/packages" "$VMWORK/pkg-stage"
}

render_overlay() {
    "$FW/build.sh" --render-only generic "$1" >&2
    echo "build.sh --render-only generic"
}

# Console markers around every uci-defaults script of the image, for the power-cut scenario.
# "<name>~lwvm-after" sorts right after <name>; "<name minus last char, that char - 1>~lwvm-before"
# right before it, when that character has a predecessor that is safe in a file name.
# The after script also syncs and then says "synced": a cut after that marker finds the script's
# changes on disk while the script itself is still in /etc/uci-defaults, so it runs a second time.
add_markers() {
    local stage=$1 f name last prev
    for f in "$2"/etc/uci-defaults/*; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        printf '#!/bin/sh\necho "LWVM-MARK after %s" >/dev/console\nsync\n' "$name" \
            >"$stage/etc/uci-defaults/$name~lwvm-after"
        printf 'echo "LWVM-MARK synced %s" >/dev/console\n' "$name" \
            >>"$stage/etc/uci-defaults/$name~lwvm-after"
        last=${name: -1}
        case $last in [1-9b-zB-Z]) ;; *) continue ;; esac
        prev=$(printf '%b' "\\0$(printf '%03o' $(($(printf '%d' "'$last") - 1)))")
        printf '#!/bin/sh\necho "LWVM-MARK before %s" >/dev/console\n' "$name" \
            >"$stage/etc/uci-defaults/${name%?}$prev~lwvm-before"
    done
}

detect_lan_ip() {
    local ip
    ip=${LWVM_LAN_IP:-}
    [ -n "$ip" ] || ip=$(grep -rhoE "network\.lan\.ipaddr=['\"]?[0-9]+(\.[0-9]+){3}" \
        "$1/etc/uci-defaults" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+){3}' | head -n1 || true)
    echo "${ip:-192.168.1.1}"
}

WORK=
cleanup() { [ -z "$WORK" ] || rm -rf "$WORK"; }

main() {
    local src=${1:-} stage key img src_note qmi_pkg
    mkdir -p "$VMWORK/image"
    ensure_ib
    tune_ib
    WORK=$(mktemp -d "$VMWORK/stage.XXXXXX")
    trap cleanup EXIT
    mkdir -p "$WORK/overlay" "$WORK/files"
    if [ -n "$src" ]; then
        [ -d "$src" ] || die "overlay dir not found: $src"
        cp -a "$src/." "$WORK/overlay/"
        src_note="given overlay $src"
        [ -f "$src-passwords.txt" ] && cp "$src-passwords.txt" "$WORK/overlay-passwords.txt"
    else
        src_note=$(render_overlay "$WORK/overlay")
    fi
    stage=$WORK/files
    cp -a "$WORK/overlay/." "$stage/"
    cp -a "$VMDIR/overlay/." "$stage/"
    chmod 0755 "$stage"/etc/init.d/lw-vm-*
    add_markers "$stage" "$WORK/overlay"
    # R12d, D82: the VM runs the same handler as the router image, derived from the x86 package
    # (needs the package feeds, so a run with a cached image still reaches the network)
    qmi_pkg=$(qmi_derive "$IB" "$stage" "$WORK/qmi")
    log "/$QMI_SH_REL from $qmi_pkg without its network scan"

    # the build time in /etc/lw-build changes with every render; it alone does not need a new image
    key=$( {
        tar -C "$stage" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
            --exclude=./etc/lw-build -cf - .
        printf '%s\n' "${PACKAGES[@]}"
        sha256sum "$0" "$IB/.config"
    } | sha256sum | cut -c1-12)
    img=$VMWORK/image/$key
    if [ ! -f "$img/disk.img" ]; then
        log "building image $key ($src_note)"
        mkdir -p "$img.tmp"
        make -C "$IB" image PROFILE=generic PACKAGES="${PACKAGES[*]}" FILES="$stage" \
            BIN_DIR="$img.tmp/bin" EXTRA_IMAGE_NAME=lwvm >"$img.tmp/build.log" 2>&1 ||
            die "ImageBuilder failed, see $img.tmp/build.log"
        qmi_verify "$IB"
        # OpenWrt appends metadata after the gzip stream, so gzip warns "trailing garbage", exit 2
        gzip -dc "$img.tmp"/bin/*-squashfs-combined.img.gz >"$img.tmp/disk.img" 2>/dev/null ||
            [ $? = 2 ]
        cp "$img.tmp"/bin/*.manifest "$img.tmp/manifest"
        # the password card of this render, so tests can compare WiFi key and root hash
        [ -f "$WORK/overlay-passwords.txt" ] && cp "$WORK/overlay-passwords.txt" "$img.tmp/passwords.txt"
        detect_lan_ip "$WORK/overlay" >"$img.tmp/lan_ip"
        echo "$src_note" >"$img.tmp/overlay.txt"
        rm -rf "$img"
        mv "$img.tmp" "$img"
    else
        log "image $key is up to date ($src_note)"
    fi
    touch "$img"
    ln -sfn "$key" "$VMWORK/image/current"
    prune_images
    echo "$img"
}

# Keep the three most recently used images (about 150 MB each); older ones are rebuilt on demand.
prune_images() {
    local d
    find "$VMWORK/image" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -rn |
        tail -n +4 | cut -d' ' -f2- | while read -r d; do
        rm -rf "$d"
    done
}

main "$@"
