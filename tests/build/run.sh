#!/usr/bin/env bash
# Run the host-side build tests in order, then the first-boot tests on the overlays that
# 30-render.sh leaves in tests/.out/render. --quick skips the ImageBuilder builds (60-images.sh).
set -euo pipefail
FW="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
for t in "$FW"/tests/build/[0-9][0-9]-*.sh; do
    [ "${1:-}" = --quick ] && [[ $t == */60-images.sh ]] && continue
    if out=$("$t" 2>&1); then
        echo "PASS ${t#"$FW"/} ${out##*$'\n'}"
    else
        echo "FAIL ${t#"$FW"/}"
        printf '%s\n' "$out" | tail -n 20 | sed 's/^/    /'
        fail=1
    fi
done
"$FW/tests/run-all.sh" firstboot || fail=1
exit "$fail"
