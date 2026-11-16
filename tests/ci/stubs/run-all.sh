#!/usr/bin/env bash
# Stand-in for tests/run-all.sh; STUB_ROOTFS_TESTS is pass (default), fail or skip.
set -euo pipefail
echo "tests/run-all.sh $*" >>"$STUB_REC/calls"
echo "PASS tests/smoke/boot.sh"
case ${STUB_ROOTFS_TESTS:-pass} in
fail)
    echo "FAIL tests/ladder/restart.sh"
    echo "    FAIL: made-up detail"
    exit 1
    ;;
skip) echo "SKIP tests/hostnet/qr-roundtrip.sh (bwrap cannot make a namespace here)" ;;
esac
