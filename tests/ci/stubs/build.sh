#!/usr/bin/env bash
# Stand-in for build.sh in the scratch repo of tests/ci: records the call, leaves fake image files.
# STUB_REC: where it records; STUB_WRITE_CARD=1 also writes a password card (the bug R53i guards).
set -euo pipefail
FW="$(cd "$(dirname "$0")" && pwd)"
echo "build.sh $*" >>"$STUB_REC/calls"
# R53b: the profile text must not be in the environment of a build step
[ -z "${LW_PROFILE+x}" ] || echo "build.sh saw LW_PROFILE" >>"$STUB_REC/calls"
if [ "$1" = --render-only ]; then
    [ -f "$FW/profiles/$2.conf" ] || exit 1
    mkdir -p "$3"
    exit 0
fi
name=$1
stat -c %a "$FW/profiles/$name.conf" >"$STUB_REC/profile-mode"
cp "$FW/profiles/$name.conf" "$STUB_REC/profile-seen"
mkdir -p "$LW_IMAGE"
echo "fake image of $name" >"$LW_IMAGE/$name-sysupgrade.bin"
echo "fake manifest of $name" >"$LW_IMAGE/$name.manifest"
echo "not for the artifact" >"$LW_IMAGE/leftover.bin"
if [ "${STUB_WRITE_CARD:-}" = 1 ]; then echo "wifi=card" >"$LW_IMAGE/$name-passwords.txt"; fi
sha256sum "$LW_IMAGE/$name-sysupgrade.bin"
