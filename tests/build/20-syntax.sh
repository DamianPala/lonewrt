#!/usr/bin/env bash
# SPEC R6: a syntax error in any image script (an executable with a shebang or a sourced
# uci-defaults file) stops the build with the file's name before ImageBuilder runs and leaves no
# file in image/.
# shellcheck source=tests/build/lib.bash
source "$(dirname "$0")/lib.bash"
scratch syntax
S=$SCRATCH/src
I=$SCRATCH/image
mkdir -p "$I"
before=$(listing "$I")

build() { LW_SRC=$S LW_IMAGE=$I "$FW/build.sh" "$@"; }

cp -a "$FW/src" "$S"
# shellcheck disable=SC2016  # the $1 belongs to the broken script, not to this test
printf '#!/bin/sh\nif [ -n "$1" ]; then\n    echo open\n' >"$S/files/usr/sbin/lw-broken"
expect_fail_with "syntax error in usr/sbin/lw-broken" build generic
expect_fail_with "syntax error in usr/sbin/lw-broken" build --render-only generic "$SCRATCH/r1"
[ ! -e "$SCRATCH/r1" ] || fail "--render-only left output after a syntax error"

# A sourced file without a shebang is checked too
mv "$S/files/usr/sbin/lw-broken" "$S/files/etc/uci-defaults/50-broken"
sed -i 1d "$S/files/etc/uci-defaults/50-broken"
expect_fail_with "syntax error in etc/uci-defaults/50-broken" build generic

[ "$(listing "$I")" = "$before" ] || fail "a failed build changed image/: $(listing "$I")"
echo ok
