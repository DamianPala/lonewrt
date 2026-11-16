#!/usr/bin/env bash
# SPEC R53d, D105: the run lifts the userns block on GitHub only, runs tests/build/run.sh --quick and
# tests/run-all.sh (never the VM bench), and a FAIL or a SKIP stops it naming the test, with no files
# in the output folder. A missing host tool is installed on GitHub and named locally.
# shellcheck source=tests/ci/lib.bash
source "$(dirname "$0")/lib.bash"
ci_setup tests

# the two runners, in order, and no VM bench
ci_run "$FX"
ci_expect_ok
grep -nE '^(tests/build/run.sh|tests/run-all.sh)' "$REC/calls" | cut -d: -f2 | paste -sd'|' - |
    grep -qx 'tests/build/run.sh --quick|tests/run-all.sh ' ||
    fail "R53d: the runners were not run in order with their arguments: $(cat "$REC/calls")"
! grep -q 'tests/vm' "$REC/calls" || fail "R53d: the VM bench ran"
# D105: dependencies come without the vm group (the bench is not part of a run)
grep -qE '^fetch-deps.sh --quiet ib extra gawk rootfs jpeg$' "$REC/calls" ||
    fail "the dependencies were not fetched as the run needs: $(grep fetch-deps "$REC/calls")"
grep -qE '^fetch-deps.sh --quiet rootfs$' "$REC/calls" || fail "build.sh's check ran before the rootfs was there"
! grep -q 'vm' <(grep fetch-deps "$REC/calls") || fail "the vm group was fetched"

# D105: locally nothing touches the machine; on GitHub the userns block is lifted, once, exactly
[ ! -e "$REC/sudo" ] || fail "D105: a local run used sudo: $(cat "$REC/sudo")"
ci_run "$FX" GITHUB_ACTIONS=true
ci_expect_ok
[ "$(cat "$REC/sudo")" = 'sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0' ] ||
    fail "D105: the sudo calls on GitHub were: $(cat "$REC/sudo")"

# R53d: a test that fails, one that prints SKIP, and a runner that dies: each stops the run
ci_run "$FX" STUB_BUILD_TESTS=fail
ci_expect_stop "tests/build/30-render.sh"
! ci_called '^tests/run-all.sh' || fail "R53d: the next runner ran after a failure"
ci_run "$FX" STUB_ROOTFS_TESTS=fail
ci_expect_stop "FAIL tests/ladder/restart.sh"
ci_run "$FX" STUB_ROOTFS_TESTS=skip
ci_expect_stop "SKIP tests/hostnet/qr-roundtrip.sh" "bwrap cannot make a namespace"
ci_run "$FX" STUB_BUILD_TESTS=runner-error
ci_expect_stop "exited with status 3"
# the stub build is called too, so a failure after it still leaves no file in the output folder
ci_called '^build.sh router$' || fail "the build did not run before the tests"

# a missing tool: named locally, installed on GitHub (R53d: a SKIP is a failure)
rm "$BIN/zbarimg" "$BIN/qrencode" 2>/dev/null || true
ci_run "$FX"
ci_expect_stop "zbarimg" "zbar-tools"
ci_called '^build.sh [a-z]' && fail "the build ran with a tool missing"
ci_run "$FX" GITHUB_ACTIONS=true
ci_expect_ok
grep -qE '^sudo apt-get update' "$REC/sudo" || fail "no apt-get update before the install"
grep -qE '^sudo env DEBIAN_FRONTEND=noninteractive apt-get install .*zbar-tools' "$REC/sudo" ||
    fail "zbar-tools was not installed: $(cat "$REC/sudo")"
echo "tests and host ok"
