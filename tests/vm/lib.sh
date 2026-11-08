#!/usr/bin/env bash
# Helpers for the VM scenarios tests/vm/[0-9][0-9]-*.sh (sourced, bash). One scenario = one or more
# fresh guests from the image in $LWVM_IMAGE_DIR (default: the last one build-image.sh made), each
# with its own run directory under $VMWORK/run/, its own modem stand-in, and QEMU killed on exit.
# Checks never stop a scenario; `finish` prints PASS/FAIL with the count and the duration.
set -euo pipefail
# decimal points in awk/printf output, whatever the caller's locale
export LC_ALL=C

VMDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FW="$(cd "$VMDIR/../.." && pwd)"
LW_WORK=${LW_WORK:-$FW/work}
VMWORK=${LWVM_WORK:-$LW_WORK/vm}
IMAGE=${LWVM_IMAGE_DIR:-$VMWORK/image/current}
SCENARIO=$(basename "$0" .sh)
RUN=
LAN_IP=
MODEM_PID=
CHECKS=0
FAILS=0
T0=$SECONDS

vm_py() { python3 -I "$VMDIR/vm.py" "$@"; }

note() { echo "  ..    $*"; }

# gnote SCRIPT: show what SCRIPT prints in the guest, for the record (never fails the scenario)
gnote() { vm_sh "$1" 2>&1 | sed 's/^/  ..    /' || true; }

# vm_init [SUFFIX]: a fresh guest: new run dir with a pristine copy of the image's disk (= flash)
vm_init() {
    vm_cleanup
    RUN=$VMWORK/run/$SCENARIO${1:+-$1}
    if [ ! -f "$IMAGE/disk.img" ]; then
        echo "no image in $IMAGE, run tests/vm/build-image.sh" >&2
        exit 2
    fi
    rm -rf "$RUN"
    mkdir -p "$RUN/modem"
    cp --reflink=auto "$IMAGE/disk.img" "$RUN/disk.img"
    LAN_IP=$(cat "$IMAGE/lan_ip")
}

# modem_start [INIT_JSON]: the AT modem stand-in for this guest, seeded with INIT_JSON (modem.py)
modem_start() {
    [ -z "$MODEM_PID" ] || return 0
    [ -z "${1:-}" ] || printf '%s\n' "$1" >"$RUN/modem/init.json"
    python3 -I "$VMDIR/modem.py" --socket "$RUN/modem.sock" --dir "$RUN/modem" \
        2>>"$RUN/modem/modem.err" &
    MODEM_PID=$!
}

# modem_get KEY: one value of the stand-in's state as JSON, e.g. [6, 0, 0]
modem_get() {
    python3 -I -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))[sys.argv[2]]))' \
        "$RUN/modem/state.json" "$1"
}

# vm_start [--no-modem]: power on (keeps the disk, so it is also the start after a power cut)
vm_start() {
    case " $* " in *" --no-modem "*) ;; *) modem_start '' ;; esac
    vm_py start --run "$RUN" --lan-ip "$LAN_IP" "$@" >>"$RUN/harness.log"
}

vm_wait_ready() { vm_py wait-ready --run "$RUN" --timeout "${1:-180}" >>"$RUN/harness.log"; }

# vm_sh SCRIPT [TIMEOUT]: run SCRIPT in the guest, its output on stdout, its exit code as ours
vm_sh() { vm_py sh --run "$RUN" --timeout "${2:-60}" "$1"; }

vm_reboot() {
    vm_sh '(sleep 1; reboot) >/dev/null 2>&1 &' >/dev/null
    vm_wait_ready "${1:-180}"
}

# vm_wait_for SCRIPT TIMEOUT: poll the guest until SCRIPT succeeds; 1 when it never did
vm_wait_for() {
    local end=$((SECONDS + $2))
    while [ "$SECONDS" -lt "$end" ]; do
        vm_sh "$1" 30 >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

vm_cleanup() {
    if [ -n "$RUN" ] && [ -d "$RUN" ]; then
        vm_py stop --run "$RUN" || true
    fi
    if [ -n "$MODEM_PID" ]; then
        kill "$MODEM_PID" 2>/dev/null || true
        wait "$MODEM_PID" 2>/dev/null || true
        MODEM_PID=
    fi
}

trap vm_cleanup EXIT
trap 'exit 130' INT TERM

# check DESC CMD...: one assertion; output of a failing CMD is shown under it
check() {
    local desc=$1 out rc=0
    shift
    CHECKS=$((CHECKS + 1))
    out=$("$@" 2>&1) || rc=$?
    if [ "$rc" = 0 ]; then
        echo "  ok    $desc"
    else
        FAILS=$((FAILS + 1))
        echo "  FAIL  $desc"
        [ -z "$out" ] || printf '%s\n' "$out" | tail -n 12 | sed 's/^/          /'
    fi
}

# gcheck DESC SCRIPT [TIMEOUT]: assertion run in the guest
gcheck() { check "$1" vm_sh "$2" "${3:-60}"; }

# must DESC CMD...: a step the rest of the scenario depends on; on failure the scenario ends
must() {
    local desc=$1 before=$FAILS
    shift
    check "$desc" "$@"
    [ "$FAILS" = "$before" ] || finish
}

finish() {
    local verdict=PASS
    [ "$FAILS" = 0 ] || verdict=FAIL
    echo "$verdict $SCENARIO ($((CHECKS - FAILS))/$CHECKS checks, $((SECONDS - T0)) s)"
    exit $((FAILS > 0))
}

# uci_export_normalized: `uci export` without the values OpenWrt draws at random on every first
# boot (IPv6 ULA prefix, DHCPv6 DUID), so two first boots of one image compare equal
uci_export_normalized() {
    vm_sh 'uci export' | grep -v -E "^[[:space:]]*option (ula_prefix|dhcp_default_duid) "
}

# profile_value KEY: a value from profiles/generic.conf (KEY='value' lines), empty when absent
profile_value() {
    sed -n "s/^$1='\(.*\)'\$/\1/p" "$FW/profiles/generic.conf" 2>/dev/null | head -n1
}

# card_value KEY: a value from the image's password card (ssid=, wifi=, root=), empty when absent
card_value() {
    [ -f "$IMAGE/passwords.txt" ] || return 0
    sed -n "s/^$1=//p" "$IMAGE/passwords.txt" 2>/dev/null | head -n1
}
