#!/usr/bin/env bash
# Run every tests/<area>/*.sh in its own fresh rootfs sandbox; prints PASS/FAIL per test.
# Optional argument: one area (ladder, modem, smoke ...) to run only that directory.
set -euo pipefail
FW="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
for t in "$FW"/tests/${1:-*}/*.sh; do
    rel=${t#"$FW"/}
    case $rel in tests/rootfs/* | tests/vm/* | tests/build/*) continue ;; esac
    if out=$("$FW/tests/rootfs/run.sh" "$rel" 2>&1); then
        echo "PASS $rel"
    else
        echo "FAIL $rel"
        printf '%s\n' "$out" | tail -n 20 | sed 's/^/    /'
        fail=1
    fi
done
exit "$fail"
