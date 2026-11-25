#!/usr/bin/env bash
# Build (or reuse) the small LAN guest of tests/vm/80-tailscale.sh: the same official x86/64
# ImageBuilder as build-image.sh, no router overlay, just the files of tests/vm/lan-guest/ (DHCP on
# its one NIC, a web server on port 80 whose CGI writes the source address of every request into
# /tmp/lwvm-src.log, and the console marker of the bench).
# Usage: tests/vm/build-lan-guest.sh
# Prints the image directory (disk.img) as the last line; cached by a hash of its inputs.
set -euo pipefail

VMDIR="$(cd "$(dirname "$0")" && pwd)"
FW="$(cd "$VMDIR/../.." && pwd)"
LW_WORK=${LW_WORK:-$FW/work}
VMWORK=${LWVM_WORK:-$LW_WORK/vm}
IB=$VMWORK/ib
# ImageBuilder wants GNU awk; the laptop only has mawk
export PATH=$LW_WORK/tools/bin:$PATH
# uhttpd serves port 80 with a CGI directory; the rest of the default x86 set stays, except the
# router parts (a DHCP server, a firewall and the IPv6 daemon would fight the router's)
# wireguard-tools (and the kernel module it pulls in) make the guest a WireGuard peer for
# tests/vm/96-clat-verify.sh
PACKAGES=(uhttpd wireguard-tools -dnsmasq -firewall4 -odhcpd-ipv6only -ppp -ppp-mod-pppoe)

die() { echo "build-lan-guest: $*" >&2; exit 1; }

[ -f "$IB/Makefile" ] || die "no ImageBuilder in $IB: run tests/vm/build-image.sh once"

key=$( {
    tar -C "$VMDIR/lan-guest" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - .
    # the shared init script of the bench is part of the guest
    sha256sum "$VMDIR/overlay/etc/init.d/lw-vm-ready"
    printf '%s\n' "${PACKAGES[@]}"
    sha256sum "$0" "$IB/.config"
} | sha256sum | cut -c1-12)
img=$VMWORK/lan-guest/$key
if [ -f "$img/disk.img" ]; then
    echo "$img"
    exit 0
fi

work=$(mktemp -d "$VMWORK/stage-lg.XXXXXX")
trap 'rm -rf "$work"' EXIT
cp -a "$VMDIR/lan-guest/." "$work/"
mkdir -p "$work/etc/init.d"
cp "$VMDIR/overlay/etc/init.d/lw-vm-ready" "$work/etc/init.d/lw-vm-ready"
chmod 0755 "$work"/etc/init.d/* "$work"/etc/uci-defaults/* "$work"/www/cgi-bin/*
mkdir -p "$img.tmp"
exec 9<"$IB"
flock 9
make -C "$IB" image PROFILE=generic PACKAGES="${PACKAGES[*]}" FILES="$work" \
    BIN_DIR="$img.tmp/bin" EXTRA_IMAGE_NAME=lwvmlan >"$img.tmp/build.log" 2>&1 ||
    die "ImageBuilder failed, see $img.tmp/build.log"
# OpenWrt appends metadata after the gzip stream, so gzip warns "trailing garbage", exit 2
gzip -dc "$img.tmp"/bin/*-squashfs-combined.img.gz >"$img.tmp/disk.img" 2>/dev/null || [ $? = 2 ]
rm -rf "$img"
mv "$img.tmp" "$img"
echo "$img"
