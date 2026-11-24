#!/usr/bin/env bash
# SPEC R76e, R2, D169: every image holds the packages 464xlat and kmod-nat46, in every place the
# list lives: the "Included" table of packages.md (not as a tailscale image's only), PACKAGES of
# build.sh (not TS_PACKAGES), the list of the VM bench, and the overlay carries the script and the
# hotplug file that use them (R76 to R76d). The manifest of a built image has them: 60-images.sh.
# shellcheck source=tests/build/lib.bash
source "$(dirname "$0")/lib.bash"
scratch clatpkg

want=(464xlat kmod-nat46)

# the names of the "Included" rows of packages.md, whole rows kept for the tailscale mark
included=$(awk '/^## /{on = index($0, "Included") > 0; next} on && /^\| `/' "$FW/packages.md")
for pkg in "${want[@]}"; do
    row=$(grep -F "\`$pkg\`" <<<"$included" | head -n 1 || true)
    [ -n "$row" ] || fail "R76e: packages.md \"Included\" has no row with $pkg"
    grep -q 'R76e' <<<"$row" || fail "R76e: the row of $pkg does not cite R76e"
    ! grep -qF "only with \`TS_ENABLED='1'\`" <<<"$row" || fail "R76e: the row of $pkg is a tailscale image's only"
    # the first column holds the name itself, not a dependency in parentheses
    cut -d'|' -f2 <<<"$row" | sed 's/([^)]*)//g' | grep -qF "\`$pkg\`" || fail "R76e: $pkg is only a dependency in its row"
done

list_of() { sed -n "/^$2=(/,/^)/p" "$1" | sed '1d;$d' | tr ' ' '\n' | sed '/^$/d'; }
for pkg in "${want[@]}"; do
    list_of "$FW/build.sh" PACKAGES | grep -qxF "$pkg" || fail "R76e: PACKAGES of build.sh lacks $pkg"
    ! sed -n 's/^TS_PACKAGES=(\(.*\))$/\1/p' "$FW/build.sh" | tr ' ' '\n' | grep -qxF "$pkg" ||
        fail "R76e: TS_PACKAGES of build.sh has $pkg: it is for every image"
    ! sed -n 's/^REMOVED_PACKAGES=(\(.*\))$/\1/p' "$FW/build.sh" | tr ' ' '\n' | grep -qxF "$pkg" ||
        fail "R76e: build.sh removes $pkg"
    list_of "$FW/tests/vm/build-image.sh" PACKAGES | grep -qxF "$pkg" || fail "R76e: the VM bench lacks $pkg"
done

# the files of the image that use them: rendered, executable, with the syntax check of the build
LW_IMAGE=$SCRATCH/image LW_PROFILES=$FW/profiles \
    "$FW/build.sh" --render-only generic "$SCRATCH/overlay" >/dev/null 2>"$SCRATCH/err" ||
    fail "the generic overlay does not render: $(tail -n 3 "$SCRATCH/err")"
[ -x "$SCRATCH/overlay/usr/sbin/lw-clat-check" ] || fail "R76: the overlay has no executable /usr/sbin/lw-clat-check"
# the dispatch is in the existing hotplug file (a file of its own costs a fork per event on every
# session), made of builtins; no file of its own
[ ! -e "$SCRATCH/overlay/etc/hotplug.d/iface/96-lw-clat" ] || fail "R76b: a hotplug file of its own for the translation"
hp=$SCRATCH/overlay/etc/hotplug.d/iface/90-lw-lan6
# shellcheck disable=SC2016  # the $ belongs to the file under test
for w in 'lw-clat-check new' 'lw-clat-check down' '$d/v6only' '$d/active'; do
    grep -qF -- "$w" "$hp" || fail "R76b: the hotplug dispatch (90-lw-lan6) lacks '$w'"
done
echo ok
