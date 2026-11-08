#!/usr/bin/env bash
# SPEC R5: profiles other than generic.conf, everything a build or a test leaves behind (image/,
# work/, tests/.out/) and the optional private-values list stay out of git, while the image
# sources and test fixtures stay in it.
# shellcheck source=tests/build/lib.bash
source "$(dirname "$0")/lib.bash"
REPO=$(git -C "$FW" rev-parse --show-toplevel)
ignored=$(git -C "$REPO" check-ignore "$FW/image/x.bin" "$FW/profiles/mine.conf" "$FW/profiles/mine/" \
    "$FW/work" "$FW/tests/.out/x" "$FW/tests/build/private-values.txt")
[ "$(wc -l <<<"$ignored")" = 6 ] || fail "git ignores only: $ignored"
! git -C "$REPO" check-ignore -q "$FW/profiles/generic.conf" || fail "profiles/generic.conf is ignored"

# A bare `config` rule in a parent .gitignore would drop src/files/etc/config/*.
mapfile -t sources < <(find "$FW/src" "$FW/tests/build" "$FW/tests/firstboot" -type f \
    ! -name private-values.txt ! -path '*/__pycache__/*')
if hidden=$(git -C "$REPO" check-ignore "${sources[@]}"); then
    fail "git ignores sources: $(tr '\n' ' ' <<<"$hidden")"
fi
echo ok
