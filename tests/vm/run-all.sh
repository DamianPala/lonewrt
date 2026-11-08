#!/usr/bin/env bash
# Build (or reuse) the VM image and run the VM scenarios tests/vm/[0-9][0-9]-*.sh.
# Usage: tests/vm/run-all.sh [--overlay DIR] [-j N] [SCENARIO ...]
#   --overlay DIR  rendered overlay to test (default: build-image.sh decides, see there)
#   -j N           run N scenarios at once (each guest has 256 MB and one vCPU)
#   SCENARIO       e.g. 10-firstboot or firstboot; default: all
# Prints PASS/FAIL per scenario with its duration; full output in $VMWORK/logs/<scenario>.log.
set -euo pipefail
export LC_ALL=C

VMDIR="$(cd "$(dirname "$0")" && pwd)"
FW="$(cd "$VMDIR/../.." && pwd)"
LW_WORK=${LW_WORK:-$FW/work}
VMWORK=${LWVM_WORK:-$LW_WORK/vm}
overlay=()
jobs=1
picks=()
while [ $# -gt 0 ]; do
    case $1 in
        --overlay) overlay=("$2"); shift 2 ;;
        -j) jobs=$2; shift 2 ;;
        -h | --help) sed -n '2,8p' "$0"; exit 0 ;;
        *) picks+=("$1"); shift ;;
    esac
done

scenarios=()
for s in "$VMDIR"/[0-9][0-9]-*.sh; do
    name=$(basename "$s" .sh)
    if [ ${#picks[@]} -gt 0 ]; then
        keep=0
        for p in "${picks[@]}"; do
            [ "$name" = "$p" ] || [ "${name#[0-9][0-9]-}" = "$p" ] && keep=1
        done
        [ "$keep" = 1 ] || continue
    fi
    scenarios+=("$s")
done
[ ${#scenarios[@]} -gt 0 ] || { echo "no scenario matches: ${picks[*]}" >&2; exit 2; }

# shellcheck disable=SC2329 # called from the trap below
descendants() {
    local c
    for c in $(pgrep -P "$1"); do
        echo "$c"
        descendants "$c"
    done
}
# Scenarios stop their guests on TERM; pass an INT or TERM on to the build and all scenarios, so no
# QEMU outlives the run. Everything long runs as a background job: bash runs a trap only after a
# foreground child has finished, but at once while it sits in `wait`.
# shellcheck disable=SC2046 # one PID per word
trap 'kill $(descendants $$) 2>/dev/null; wait; exit 130' INT TERM

t0=$SECONDS
mkdir -p "$VMWORK/logs"
"$VMDIR/build-image.sh" "${overlay[@]}" >"$VMWORK/logs/build-image.out" &
wait $!
img=$(tail -n1 "$VMWORK/logs/build-image.out")
export LWVM_IMAGE_DIR=$img
echo "image $img ($(cat "$img/overlay.txt")), build/check $((SECONDS - t0)) s"

run_one() {
    local s=$1 name t rc=0
    name=$(basename "$s" .sh)
    t=$SECONDS
    "$s" >"$VMWORK/logs/$name.log" 2>&1 </dev/null || rc=$?
    echo "$rc $((SECONDS - t))" >"$VMWORK/logs/$name.rc"
}

report_one() {
    local name rc dt
    name=$(basename "$1" .sh)
    read -r rc dt <"$VMWORK/logs/$name.rc"
    if [ "$rc" = 0 ]; then
        echo "PASS $name (${dt} s)"
    else
        echo "FAIL $name (${dt} s)"
        sed 's/^/    /' "$VMWORK/logs/$name.log"
    fi
    [ "$rc" = 0 ]
}

fail=0
running=0
for s in "${scenarios[@]}"; do
    if [ "$jobs" -le 1 ]; then
        run_one "$s" &
        wait $!
        report_one "$s" || fail=1
        continue
    fi
    run_one "$s" &
    running=$((running + 1))
    if [ "$running" -ge "$jobs" ]; then
        wait -n || true
        running=$((running - 1))
    fi
done
if [ "$jobs" -gt 1 ]; then
    wait || true
    for s in "${scenarios[@]}"; do report_one "$s" || fail=1; done
fi
verdict=PASS
[ "$fail" = 0 ] || verdict=FAIL
echo "$verdict tests/vm: ${#scenarios[@]} scenarios in $((SECONDS - t0)) s"
exit "$fail"
