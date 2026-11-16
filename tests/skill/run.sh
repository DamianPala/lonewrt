#!/usr/bin/env bash
# Run the host-side tests of the agent skill (tests/skill/[0-9][0-9]-*.sh) in order, one PASS/FAIL line
# each, like tests/ci/run.sh. They need no ImageBuilder, no network and no root: they read the skill
# file and run its one command block that decides something (the tunnel-limit comparison) against a
# stand-in for ssh. Exit code 1 when any test failed.
set -euo pipefail
FW="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
for t in "$FW"/tests/skill/[0-9][0-9]-*.sh; do
    if out=$("$t" 2>&1); then
        echo "PASS ${t#"$FW"/} ${out##*$'\n'}"
    else
        echo "FAIL ${t#"$FW"/}"
        printf '%s\n' "$out" | tail -n 20 | sed 's/^/    /'
        fail=1
    fi
done
exit "$fail"
