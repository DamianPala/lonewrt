#!/usr/bin/env bash
# Run one test script inside the official OpenWrt 25.12.6 x86_64 rootfs: the same busybox, uci,
# jsonfilter and coreutils timeout as the router, a throwaway writable overlay, no network.
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

exec bwrap --overlay-src "$ROOTFS" --tmp-overlay / \
    --dev /dev "${port[@]}" --proc /proc --tmpfs /tmp \
    --ro-bind "$FW" /fw \
    --unshare-user --uid 0 --gid 0 --unshare-net --unshare-pid --die-with-parent \
    --clearenv --setenv PATH /fw/tests/stubs:/usr/sbin:/usr/bin:/sbin:/bin \
    --setenv HOME /root --setenv LW_TEST /lwtest --setenv LW_UPTIME_FILE /lwtest/uptime \
    --setenv LW_NET_STATS /lwtest/stats \
    /bin/sh "/fw/$1" "${@:2}"
