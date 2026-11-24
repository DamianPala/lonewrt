#!/usr/bin/env bash
# Run one test script inside the official OpenWrt 25.12.6 x86_64 rootfs: the same busybox, uci,
# jsonfilter and coreutils timeout as the router, a throwaway writable root, no network.
# Usage: tests/rootfs/run.sh tests/<area>/<test>.sh   (path relative to the firmware directory)
# The rootfs comes from ./fetch-deps.sh into $LW_WORK/dl/x86/rootfs (LW_WORK defaults to work/).
# LW_NO_PORT=1 starts without /dev/ttyUSB2, to test a modem that never appears.
set -euo pipefail

FW="$(cd "$(dirname "$0")/../.." && pwd)"
LW_WORK=${LW_WORK:-$FW/work}
ROOTFS=${LW_ROOTFS:-$LW_WORK/dl/x86/rootfs}
[ -x "$ROOTFS/bin/busybox" ] || { echo "no rootfs at $ROOTFS: run ./fetch-deps.sh" >&2; exit 2; }
[ $# -ge 1 ] || { echo "usage: $0 tests/<area>/<test>.sh" >&2; exit 2; }

port=(--dev-bind /dev/null /dev/ttyUSB2)
[ "${LW_NO_PORT:-0}" = 1 ] && port=()

# shellcheck source=tests/rootfs/root.bash
. "$FW/tests/rootfs/root.bash"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

# R12d, D82: tests/qmi run the image's qmi.sh, derived as build.sh does (the repo keeps no copy)
qmi_args=()
if [[ $1 == tests/qmi/* ]]; then
    "$FW/tests/qmi/derive.bash" "$LW_WORK/ib" "$ROOTFS" "$scratch"
    qmi_args=(--ro-bind "$scratch/qmi-overlay" /qmi-overlay --dev-bind /dev/null /dev/cdc-wdm0)
fi
# R14c: tests/watchcat run the worker and init script of the image, derived from the cached package
# (the repo keeps no copy), next to the package's own files for the comparisons with stock
if [[ $1 == tests/watchcat/* ]]; then
    "$FW/tests/watchcat/derive.bash" "$LW_WORK/ib" "$ROOTFS" "$scratch"
    qmi_args+=(--ro-bind "$scratch/wc-overlay" /wc-overlay --ro-bind "$scratch/wc-build/ext" /wc-stock)
fi
root_args "$ROOTFS" "$scratch"

# The GitHub runner starts its steps with SIGPIPE ignored, and an ignored signal passes through
# exec, so `yes | head` in a test never ended there. The router's shell has the default; so does
# the sandbox (a shell cannot undo an ignore it inherited, env can).
env --default-signal=PIPE bwrap "${ROOT_ARGS[@]}" \
    --dev /dev "${port[@]}" "${qmi_args[@]}" --proc /proc --tmpfs /tmp \
    --ro-bind "$FW" /fw \
    --unshare-user --uid 0 --gid 0 --unshare-net --unshare-pid --die-with-parent \
    --clearenv --setenv PATH /fw/tests/stubs:/usr/sbin:/usr/bin:/sbin:/bin \
    --setenv HOME /root --setenv LW_TEST /lwtest --setenv LW_UPTIME_FILE /lwtest/uptime \
    --setenv LW_NET_STATS /lwtest/stats \
    /bin/sh "/fw/$1" "${@:2}"
