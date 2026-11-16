#!/usr/bin/env bash
# Run the host-side tests of the configurator (tests/configurator/[0-9][0-9]-*.sh) in order, one
# PASS/FAIL/SKIP line each, like tests/ci/run.sh. They need no ImageBuilder, no network and no root:
# 10-static.sh reads the page, 20-browser.sh opens it from disk in a headless browser (agent-browser)
# and prints SKIP without one; the render check of build.sh uses LW_WORK like the build tests.
# Exit code 1 when any test failed.
set -euo pipefail
FW="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
for t in "$FW"/tests/configurator/[0-9][0-9]-*.sh; do
    if out=$("$t" 2>&1); then
        last=${out##*$'\n'}
        if [[ $last == SKIP* ]]; then
            echo "SKIP ${t#"$FW"/} (${last#SKIP: })"
        else
            echo "PASS ${t#"$FW"/} $last"
        fi
    else
        echo "FAIL ${t#"$FW"/}"
        printf '%s\n' "$out" | tail -n 20 | sed 's/^/    /'
        fail=1
    fi
done
exit "$fail"
