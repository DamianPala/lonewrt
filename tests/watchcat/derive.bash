#!/usr/bin/env bash
# Derives the image's watchcat files for the rootfs tests of tests/watchcat/ (SPEC R14c), as build.sh
# does, from the ImageBuilder's cached watchcat package: the overlay with the edits goes to
# SCRATCH/wc-overlay, the package's own files to SCRATCH/wc-build/ext (the stock side of the
# comparisons). The repository holds no copy of either.
# Usage: derive.bash IB ROOTFS SCRATCH
set -euo pipefail

FW="$(cd "$(dirname "$0")/../.." && pwd)"
IB=$1
# shellcheck disable=SC2034  # qmi_sh_n uses the rootfs's BusyBox
LW_ROOTFS=$2
scratch=$3

die() { echo "watchcat harness: $*" >&2; exit 1; }

# shellcheck source=qmi-handler.sh
source "$FW/qmi-handler.sh"
# shellcheck source=watchcat-handler.sh
source "$FW/watchcat-handler.sh"

# The cache holds one copy per feed rebuild of the same package (watchcat-1-r25.<hash>.apk, the same
# files in each, which the pin of the derivation checks), so the first one will do.
wc_fetch_package() {
    local pkgs=("$1"/dl/watchcat-[0-9]*.apk)
    [ -f "${pkgs[0]}" ] || die "missing $1/dl/watchcat-*.apk; run an ImageBuilder build to cache it"
    printf '%s\n' "${pkgs[0]}"
}

wc_derive "$IB" "$scratch/wc-overlay" "$scratch/wc-build" >/dev/null
