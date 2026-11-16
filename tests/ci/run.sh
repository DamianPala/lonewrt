#!/usr/bin/env bash
# Run the host-side tests of ci/github-run.sh (tests/ci/[0-9][0-9]-*.sh) in order, one PASS/FAIL line
# each, like tests/build/run.sh. They need no ImageBuilder, no network and no root: the script runs in
# a scratch copy of the repository with stand-ins for build.sh and the test runners (tests/ci/lib.bash).
# Exit code 1 when any test failed.
set -euo pipefail
FW="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
for t in "$FW"/tests/ci/[0-9][0-9]-*.sh; do
    if out=$("$t" 2>&1); then
        echo "PASS ${t#"$FW"/} ${out##*$'\n'}"
    else
        echo "FAIL ${t#"$FW"/}"
        printf '%s\n' "$out" | tail -n 20 | sed 's/^/    /'
        fail=1
    fi
done
exit "$fail"
