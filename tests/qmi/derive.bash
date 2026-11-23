#!/usr/bin/env bash
set -euo pipefail

FW="$(cd "$(dirname "$0")/../.." && pwd)"
IB=$1
# shellcheck disable=SC2034  # qmi_sh_n uses the rootfs's BusyBox
LW_ROOTFS=$2
scratch=$3

die() { echo "qmi harness: $*" >&2; exit 1; }

# shellcheck source=qmi-handler.sh
source "$FW/qmi-handler.sh"

# R12d, D82: the ImageBuilder's cached package, with the same extraction and transform as the build,
# so the tests need no network and never run a handler the image does not ship.
qmi_fetch_package() {
    local pkgs=("$1"/dl/uqmi-*.apk)
    [ -f "${pkgs[0]}" ] || die "missing $1/dl/uqmi-*.apk; run an ImageBuilder build to cache it"
    [ "${#pkgs[@]}" = 1 ] || die "multiple uqmi packages in $1/dl; use a cache with one package"
    printf '%s\n' "${pkgs[0]}"
}

qmi_derive "$IB" "$scratch/qmi-overlay" "$scratch/qmi-build"
