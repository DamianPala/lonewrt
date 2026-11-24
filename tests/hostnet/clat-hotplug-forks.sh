#!/usr/bin/env bash
# R76b, D186: the hotplug dispatch of lw-clat-check costs the owner's IPv4-only router and a
# dual-stack session nothing: not a process, not a fork. hotplug-call runs every file of
# /etc/hotplug.d/iface in a subshell per event, so a file of its own would fork once per event on
# every router; the dispatch is therefore part of 90-lw-lan6, behind a test of shell builtins. This
# counts the fork, vfork and clone calls of the image's busybox ash (the rootfs of ./fetch-deps.sh,
# under strace) for the events of those sessions, with the file of the commit before the slice
# (0dff13c) and with the file of this tree: the counts must be equal. A positive control, an
# IPv6-only session's ifup of wwan_6, must count more (it starts the check, detached).
# SKIP without strace, git or the rootfs. Usage: tests/hostnet/clat-hotplug-forks.sh (LW_WORK as for
# the rootfs tests; LW_BASE_REV to compare with another commit)
set -euo pipefail

FW="$(cd "$(dirname "$0")/../.." && pwd)"
LW_WORK=${LW_WORK:-$FW/work}
ROOTFS=${LW_ROOTFS:-$LW_WORK/dl/x86/rootfs}
BASE_REV=${LW_BASE_REV:-0dff13c}
FILE=src/files/etc/hotplug.d/iface/90-lw-lan6

skip() {
    echo "SKIP: $*"
    exit 0
}
command -v strace >/dev/null || skip "no strace on the host"
command -v git >/dev/null || skip "no git on the host"
[ -x "$ROOTFS/bin/busybox" ] || skip "no rootfs at $ROOTFS (./fetch-deps.sh)"
loader=$(compgen -G "$ROOTFS/lib/ld-musl-*.so.1" | head -n 1 || true)
[ -n "$loader" ] || skip "no musl loader in $ROOTFS"
git -C "$FW" cat-file -e "$BASE_REV:$FILE" 2>/dev/null || skip "no $BASE_REV:$FILE in this repository"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
git -C "$FW" show "$BASE_REV:$FILE" >"$tmp/base"
cp "$FW/$FILE" "$tmp/slice"
mkdir -p "$tmp/clat"

# forks FILE ACTION INTERFACE [DIR]: the number of process creations of one run of the dispatch loop
# of hotplug-call (a subshell per file) over FILE, the clat state directory being DIR
forks() {
    local file=$1 action=$2 iface=$3 dir=${4:-$tmp/clat}
    rm -f "$tmp/trace"
    # shellcheck disable=SC2016  # the $ belongs to the shell that strace runs
    ACTION=$action INTERFACE=$iface LW_CLAT_DIR=$dir strace -f -qq -o "$tmp/trace" \
        -e trace=fork,vfork,clone,clone3 \
        "$loader" --library-path "$ROOTFS/lib:$ROOTFS/usr/lib" "$ROOTFS/bin/busybox" sh -c \
        'for script in "$@"; do ( [ -f "$script" ] && . "$script" ); done' sh "$file" >/dev/null 2>&1 || true
    grep -c -E '(fork|vfork|clone|clone3)\(' "$tmp/trace" || true
}

fail=0
for ev in 'ifup wwan' 'ifup wwan_4' 'ifdown wwan' 'ifup wwan_6' 'ifup wwan_6_4' 'ifdown wwan_6' 'ifup lan' 'ifup wan'; do
    # shellcheck disable=SC2086  # the event is two words
    set -- $ev
    b=$(forks "$tmp/base" "$1" "$2")
    s=$(forks "$tmp/slice" "$1" "$2")
    if [ "$b" = "$s" ]; then
        echo "ok   $ev: $s forks (baseline $b)"
    else
        echo "FAIL $ev: $s forks, baseline $b"
        fail=1
    fi
done
# positive control: a record of an IPv6-only session makes the child's ifup start the check
mkdir -p "$tmp/clat6"
echo 17/1/1000.00 >"$tmp/clat6/v6only"
b=$(forks "$tmp/base" ifup wwan_6)
s=$(forks "$tmp/slice" ifup wwan_6 "$tmp/clat6")
if [ "$s" -gt "$b" ]; then
    echo "ok   ifup wwan_6 of an IPv6-only session: $s forks, baseline $b (the check starts)"
else
    echo "FAIL ifup wwan_6 of an IPv6-only session: $s forks, baseline $b: the measurement sees nothing"
    fail=1
fi
exit "$fail"
