#!/usr/bin/env bash
# Run every tests/<area>/*.sh in its own fresh rootfs sandbox; prints PASS/FAIL per test.
#
#   tests/run-all.sh [-j N] [area]
#
# area (ladder, modem, smoke ...) runs only that directory. The area hostnet is different: its scripts
# run on the host (they need a network port of the host, which the sandbox of the other tests
# does not have), and print SKIP when they cannot run here. The tests are independent (own bwrap
# sandbox, no network), so N of them run at once: -j N, else LW_JOBS, else 6 (half the cores of a
# 12-core host). The report keeps the order of the directory listing whatever the finishing order;
# a FAIL is followed by the last 20 lines of that test's output. Exit code 1 when any test failed.
set -euo pipefail
FW="$(cd "$(dirname "$0")/.." && pwd)"
jobs_max=${LW_JOBS:-6}
if [ "${1:-}" = -j ]; then
    [ $# -ge 2 ] || { echo "usage: $0 [-j N] [area]" >&2; exit 2; }
    jobs_max=$2
    shift 2
fi
[ $# -le 1 ] || { echo "usage: $0 [-j N] [area]" >&2; exit 2; }
[[ $jobs_max =~ ^[1-9][0-9]*$ ]] || { echo "run-all: jobs must be a positive number, got '$jobs_max'" >&2; exit 2; }

tests=()
# shellcheck disable=SC2231  # the area argument may itself be a glob
for t in "$FW"/tests/${1:-*}/*.sh; do
    [ -f "$t" ] || continue
    rel=${t#"$FW"/}
    case $rel in tests/rootfs/* | tests/vm/* | tests/build/* | tests/hostnet/*) continue ;; esac
    tests+=("$rel")
done
host_tests=()
case ${1:-hostnet} in hostnet) host_tests=("$FW"/tests/hostnet/*.sh) ;; esac
[ "${#tests[@]}" -gt 0 ] || [ "${1:-}" = hostnet ] || {
    echo "run-all: no rootfs tests in tests/${1:-*}/" >&2
    exit 2
}

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
# Ctrl-C or kill stops the running tests too: background jobs ignore SIGINT, so they get a TERM,
# and bwrap (--die-with-parent) goes with them
trap 'kill $(jobs -p) 2>/dev/null; wait; exit 130' INT TERM

# run_one INDEX REL: output to $tmp/INDEX.out, then the exit status to $tmp/INDEX.rc (a rename, so
# the printer never sees a half-written file)
run_one() {
    local rc=0
    "$FW/tests/rootfs/run.sh" "$2" >"$tmp/$1.out" 2>&1 || rc=$?
    echo "$rc" >"$tmp/$1.rc.part"
    mv "$tmp/$1.rc.part" "$tmp/$1.rc"
}

fail=0
next=0
# flush: print the finished tests in listing order, up to the first one still running
flush() {
    while [ "$next" -lt "${#tests[@]}" ] && [ -f "$tmp/$next.rc" ]; do
        if [ "$(<"$tmp/$next.rc")" = 0 ]; then
            echo "PASS ${tests[$next]}"
        else
            echo "FAIL ${tests[$next]}"
            tail -n 20 "$tmp/$next.out" | sed 's/^/    /'
            fail=1
        fi
        next=$((next + 1))
    done
}

for i in "${!tests[@]}"; do
    while [ "$(jobs -rp | wc -l)" -ge "$jobs_max" ]; do
        wait -n || true
        flush
    done
    run_one "$i" "${tests[$i]}" &
done
wait
flush

# the host tests, one at a time: PASS, SKIP (the script says why) or FAIL
for t in "${host_tests[@]}"; do
    [ -f "$t" ] || continue
    rel=${t#"$FW"/}
    rc=0
    "$t" >"$tmp/host.out" 2>&1 || rc=$?
    if [ "$rc" != 0 ]; then
        echo "FAIL $rel"
        tail -n 20 "$tmp/host.out" | sed 's/^/    /'
        fail=1
    elif grep -q '^SKIP' "$tmp/host.out"; then
        echo "SKIP $rel ($(sed -n 's/^SKIP: *//p' "$tmp/host.out" | head -n 1))"
    else
        echo "PASS $rel"
    fi
done
exit "$fail"
