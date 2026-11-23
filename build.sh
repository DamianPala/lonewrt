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
# LW_PROFILES, LW_SRC, LW_IMAGE, LW_VERSION_FILE (the VERSION file, SPEC R3b), LW_ZONES_PAGE (the
# configurator page, SPEC R3c) and LW_DEPS_LIST (the pins of deps.lst) to work on copies.
set -euo pipefail

FW="$(cd "$(dirname "$0")" && pwd)"
LW_WORK=${LW_WORK:-$FW/work}
LW_ROOTFS=${LW_ROOTFS:-$LW_WORK/dl/x86/rootfs}
PROFILES=${LW_PROFILES:-$FW/profiles}
SRC=${LW_SRC:-$FW/src}
IMAGE=${LW_IMAGE:-$FW/image}
VERSION_FILE=${LW_VERSION_FILE:-$FW/VERSION}
# the configurator, whose zone table fills an empty TIMEZONE (SPEC R3c)
ZONES_PAGE=${LW_ZONES_PAGE:-$FW/configurator/index.html}
# shellcheck disable=SC2034  # read by install_extra_packages in pinned-packages.sh
DEPS=${LW_DEPS_LIST:-$FW/deps.lst}
IB=$LW_WORK/ib
# shellcheck source=pinned-packages.sh
source "$FW/pinned-packages.sh"
# shellcheck source=qmi-handler.sh
source "$FW/qmi-handler.sh"
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
    qrencode libjpeg-turbo-utils
    tmux mtr-nojson vim
)
# The "Removed" table of packages.md (SPEC R2, D167): packages of the device's default set the image
# does not want; run_imagebuilder passes each to ImageBuilder as -name
REMOVED_PACKAGES=(ppp ppp-mod-pppoe kmod-ppp kmod-pppoe kmod-pppox)
# The "Included" rows marked "only with TS_ENABLED='1'" (SPEC R63): added for a tailscale image only
TS_PACKAGES=(tailscale kmod-tun)
# A file only a tailscale image has, in the overlay render.py made (src/render.py TS_CONFIG_REL): the
# overlay says whether this is a tailscale image, so no profile is parsed here
TS_MARKER_REL=etc/config/tailscale
# R63g, D153: the upstream versions of the `tailscale` package the tests' stand-in CLI was made from;
# a package of any other version builds with a warning. Add a version here after checking the
# stand-in against it.
TS_STANDIN_VERSIONS=(1.104.1)
# R63a, D138: the most the root file system of a tailscale image may take, in bytes
TS_ROOT_MAX_BYTES=15500000

# Scratch directory of this run: the rendered overlay with the profile's secrets, ImageBuilder output
TMP=
# Profile whose ImageBuilder leftovers still need scrubbing when the build is interrupted
SCRUB=
# 1 when the overlay of this build is a tailscale image's (R63)
WITH_TS=0
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

# Profile keys whose value is a secret (SPEC R4, D15); a profile that holds one should be 0600
SECRET_KEYS=(
    WIFI_KEY ROOT_PASSWORD ROOT_PASSWORD_HASH WWAN_PASSWORD WWAN_PIN WG_PRIVATE_KEY TG_BOT_TOKEN
    HC_PING_URL TS_AUTHKEY
)
# Private key files of profiles/<name>/ that the build copies into the image (render.py KEY_FILES;
# authorized_keys is public and not listed)
SECRET_KEY_FILES=(dropbear_ed25519_host_key dropbear_rsa_host_key)

# need CMD...: stop before any work when a host program is missing (docs/development.md, "Build host")
need() {
    local c
    for c; do command -v "$c" >/dev/null || die "$c is required on the build host (see docs/development.md, Build host)"; done
}

check_name() {
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die "profile name '$1': use letters, digits, - and _"
    [ -f "$PROFILES/$1.conf" ] || die "no profile $PROFILES/$1.conf"
}

# warn_profile_mode NAME: one warning, never an error, when the profile file holds a secret, or
# its folder holds a private key file, and group or others can read it (SPEC R3a, D78); names the
# files, never a value
warn_profile_mode() {
    local file=$PROFILES/$1.conf key loose=()
    for key in "${SECRET_KEYS[@]}"; do
        if grep -Eq "^[[:space:]]*$key='[^']+'" "$file"; then
            if is_loose "$file"; then loose+=("$file"); fi
            break
        fi
    done
    for key in "${SECRET_KEY_FILES[@]}"; do
        file=$PROFILES/$1/$key
        if [ -f "$file" ] && is_loose "$file"; then loose+=("$file"); fi
    done
    if [ "${#loose[@]}" -gt 0 ]; then
        echo "build: warning: secrets readable by group or others: chmod 600 ${loose[*]}" >&2
    fi
}

# is_loose FILE: group or others can access it
is_loose() {
    local mode
    mode=$(stat -L -c %a "$1")
    ((8#$mode & 8#077))
}

# render NAME OUT CARD_OUT: profile checks (R3), passwords (R33), overlay, sh -n (R6)
render() {
    python3 -I "$SRC/render.py" --name "$1" --profiles "$PROFILES" --src "$SRC" --out "$2" \
        --version-file "$VERSION_FILE" --card-in "$IMAGE/$1-passwords.txt" --card-out "$3" \
        --rootfs "$LW_ROOTFS" --zones "$ZONES_PAGE"
}

render_only() {
    local name=$1 dir=${2%/} parent
    check_name "$name"
    warn_profile_mode "$name"
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

# is_tailscale_overlay DIR: the overlay render.py made holds the files of a tailscale image (R63)
is_tailscale_overlay() {
    [ -f "$1/$TS_MARKER_REL" ]
}

# ts_feed_version IB WORK: the version of the `tailscale` package as the ImageBuilder's own apk
# resolves it from its repositories (R63b); WORK is the apk root qmi_derive left, with the index
# already read. The overlay needs it before the build, the manifest confirms it after (ts_check_image).
ts_feed_version() {
    local ib=$1 work=$2 arch version
    arch=$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\(.*\)"$/\1/p' "$ib/.config")
    version=$("$ib/staging_dir/host/bin/apk" --root "$work/root" --keys-dir "$ib/keys" \
        --repositories-file "$ib/repositories" --cache-dir "$work/cache" --arch "$arch" \
        list tailscale 2>"$work/apk-list.log" |
        sed -n 's/^tailscale-\([0-9][^ ]*\) .*/\1/p' | head -n1) || true
    [ -n "$version" ] ||
        die "no tailscale package in the package feeds of $ib/repositories: $(tail -n 3 "$work/apk-list.log")"
    echo "$version"
}

# ts_check_image BIN MANIFEST VERSION: a tailscale image has the package version that /etc/lw-build
# names (R63b), a version the tests' stand-in CLI was not made from is a warning (R63g, D153), and
# its root file system is within the limit (R63a, D138)
ts_check_image() {
    local bin=$1 manifest=$2 want=$3 built known size ok=0
    built=$(awk '$1 == "tailscale" {print $3; exit}' "$manifest")
    [ -n "$built" ] || die "the manifest of the image has no tailscale package"
    [ "$built" = "$want" ] ||
        die "the image has tailscale $built but /etc/lw-build says $want (the feed changed during the build?): build again"
    for known in "${TS_STANDIN_VERSIONS[@]}"; do
        if [ "${built%-r*}" = "$known" ]; then ok=1; fi
    done
    if [ "$ok" = 0 ]; then
        echo "build: warning: the tailscale package is $built; the tests' stand-in CLI was made from" \
            "${TS_STANDIN_VERSIONS[*]}: check that the commands lw-tailscale runs still behave" \
            "(SPEC R63g)" >&2
    fi
    # || true: under pipefail a missing member would end the build with tar's message, not this one
    size=$(tar -tvf "$bin" --wildcards '*/root' 2>/dev/null | awk '{print $3}') || true
    [[ $size =~ ^[0-9]+$ ]] || die "no root file in the sysupgrade archive of the image"
    [ "$size" -le "$TS_ROOT_MAX_BYTES" ] ||
        die "the root file system of the image is $size bytes, over the limit of $TS_ROOT_MAX_BYTES" \
            "for a tailscale image (SPEC R63a, D138): the free flash would be too small"
}

# run_imagebuilder NAME FILES BIN_DIR LOG: one build at a time per ImageBuilder tree; the lock
# (fd 9 on the tree) covers the package copy, make and the scrub
run_imagebuilder() {
    local rc=0 pkgs=("${PACKAGES[@]}")
    if [ "$WITH_TS" = 1 ]; then pkgs+=("${TS_PACKAGES[@]}"); fi
    pkgs+=("${REMOVED_PACKAGES[@]/#/-}")
    exec 9<"$IB"
    flock 9
    SCRUB=$1
    # Packages from outside the official feeds (packages.md)
    install_extra_packages "$IB/packages" "$TMP/extra"
    # ImageBuilder wants GNU awk; the laptop only has mawk, so a locally extracted gawk goes first
    PATH=$LW_WORK/tools/bin:$PATH make -C "$IB" image \
        PROFILE=zte_mf289f \
        PACKAGES="${pkgs[*]}" \
        FILES="$2" \
        EXTRA_IMAGE_NAME="$1" \
        BIN_DIR="$3" >"$4" 2>&1 || rc=$?
    # R12d: still before the scrub, which removes the final rootfs; a failure here ends the build
    # through die, and the EXIT trap scrubs
    if [ "$rc" -eq 0 ]; then qmi_verify "$IB"; fi
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
    local name=$1 bin manifest qmi_pkg ts_version=
    check_name "$name"
    warn_profile_mode "$name"
    mkdir -p "$IMAGE"
    TMP=$(mktemp -d "$IMAGE/.build-$name.XXXXXX")
    render "$name" "$TMP/files" "$TMP/passwords.txt"
    if is_tailscale_overlay "$TMP/files"; then WITH_TS=1; fi
    prepare_imagebuilder
    # R12d, D82: the package's qmi.sh minus its network scan goes into the overlay; no image otherwise
    qmi_pkg=$(qmi_derive "$IB" "$TMP/files" "$TMP/qmi")
    echo "build: /$QMI_SH_REL from $qmi_pkg without its network scan (R12d)" >&2
    if [ "$WITH_TS" = 1 ]; then
        ts_version=$(ts_feed_version "$IB" "$TMP/qmi") || exit 1
        printf 'tailscale=%s\n' "$ts_version" >>"$TMP/files/etc/lw-build"
        echo "build: tailscale $ts_version goes into the image (R63, R63b)" >&2
    fi
    run_imagebuilder "$name" "$TMP/files" "$TMP/bin" "$TMP/make.log"

    bin=$(compgen -G "$TMP/bin/*-$name-*-squashfs-sysupgrade.bin" | head -n1) || true
    manifest=$(compgen -G "$TMP/bin/*-$name-*.manifest" | head -n1) || true
    [ -n "$bin" ] && [ -n "$manifest" ] || die "ImageBuilder produced no sysupgrade image or manifest"
    if [ "$WITH_TS" = 1 ]; then ts_check_image "$bin" "$manifest" "$ts_version"; fi

    publish "$manifest" "$IMAGE/$name.manifest"
    # An unchanged card keeps its file, so a second build does not touch it (SPEC R33)
    if [ -f "$TMP/passwords.txt" ] && ! cmp -s "$TMP/passwords.txt" "$IMAGE/$name-passwords.txt"; then
        publish "$TMP/passwords.txt" "$IMAGE/$name-passwords.txt"
    fi
    # R33: the card is 0600 even when an older copy of it was not
    if [ -f "$TMP/passwords.txt" ]; then chmod 0600 "$IMAGE/$name-passwords.txt"; fi
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
