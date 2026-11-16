#!/usr/bin/env bash
# Stand-in for tests/build/run.sh; STUB_BUILD_TESTS is pass (default), fail or runner-error.
set -euo pipefail
echo "tests/build/run.sh $*" >>"$STUB_REC/calls"
echo "PASS tests/build/10-profile.sh ok"
case ${STUB_BUILD_TESTS:-pass} in
fail)
    echo "FAIL tests/build/30-render.sh"
    echo "    FAIL: made-up detail"
    exit 1
    ;;
runner-error)
    echo "run: something broke before a test ran"
    exit 3
    ;;
esac
