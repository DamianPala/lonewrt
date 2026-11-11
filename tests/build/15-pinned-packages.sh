#!/usr/bin/env bash
# SPEC R2a: the third-party .apk files reach the ImageBuilder only as deps.lst pins them. A scratch
# work folder with a stand-in ImageBuilder (a Makefile that does nothing) and small fake packages
# shows that an altered, a missing and an unlisted file, and two pins of one package, stop the build
# with the file's name before anything in packages/ changes; that earlier versions of the pinned
# packages are removed by exact package name and nothing else (modemband-5g is not modemband,
# libx-10.42 is not libx-16); and that the pinned set is copied. A good run ends at "produced no
# sysupgrade image", which proves the copy step passed.
# shellcheck source=tests/build/lib.bash
source "$(dirname "$0")/lib.bash"
scratch pinned
W=$SCRATCH/work
P=$SCRATCH/profiles
I=$SCRATCH/image
EXTRA=$W/dl/extra
PKG=$W/ib/packages
make_profiles "$P"
mkdir -p "$EXTRA" "$PKG" "$I"
fake_make_image >"$W/ib/Makefile"
# the build also derives qmi.sh from the uqmi package (R12d): a stand-in apk and package file
fake_qmi_ib "$W/ib"
export FAKE_QMI_SH=$FIX/fake-qmi.sh

PINNED=(foo-2.0-r1.apk luci-app-foo-1.5-r3.apk modemband-20260806-r1.apk libx-16-10.42-r1.apk)
for f in "${PINNED[@]}"; do printf 'fake %s\n' "$f" >"$EXTRA/$f"; done
sum() { sha256sum "$1" | cut -d' ' -f1; }
{
    echo '# a comment line'
    echo 'ib 0000000000000000000000000000000000000000000000000000000000000000 dl/not-used.tar.zst https://example.invalid/x'
    echo
    for f in "${PINNED[@]}"; do echo "extra $(sum "$EXTRA/$f") dl/extra/$f https://example.invalid/$f"; done
} >"$SCRATCH/deps.lst"

# files the ImageBuilder ships, other packages whose names only start like a pinned one, and
# earlier versions of the pinned packages
STAY=(base-files-1718.apk foo-bar-1.0.apk foo-extra-1.0-r1.apk modemband-5g-1.0-r1.apk
    kmod-modemband-5.4-r1.apk libx-10.42-r1.apk README.md packages.adb)
GONE=(luci-app-foo-1.0-r1.apk foo-1.0-r1.apk foo-1.9-r2.apk modemband-20250101-r1.apk
    libx-16-9.0-r1.apk)
for f in "${STAY[@]}" "${GONE[@]}"; do printf 'ib %s\n' "$f" >"$PKG/$f"; done

build() {
    LW_WORK=$W LW_ROOTFS=$FW/work/dl/x86/rootfs LW_DEPS_LIST=${DEPS:-$SCRATCH/deps.lst} \
        LW_PROFILES=$P LW_IMAGE=$I "$FW/build.sh" generic
}

before=$(listing "$PKG")

# an altered file: named, and nothing in packages/ touched
cp -p "$EXTRA/foo-2.0-r1.apk" "$SCRATCH/foo.good"
printf 'x' >>"$EXTRA/foo-2.0-r1.apk"
expect_fail_with "foo-2.0-r1.apk does not match its sha256" build
[ "$(listing "$PKG")" = "$before" ] || fail "an altered package changed packages/"
cp -p "$SCRATCH/foo.good" "$EXTRA/foo-2.0-r1.apk"

# a missing file
mv "$EXTRA/luci-app-foo-1.5-r3.apk" "$SCRATCH/luci.good"
expect_fail_with "luci-app-foo-1.5-r3.apk is missing" build
[ "$(listing "$PKG")" = "$before" ] || fail "a missing package changed packages/"
mv "$SCRATCH/luci.good" "$EXTRA/luci-app-foo-1.5-r3.apk"

# a file that deps.lst does not list
printf 'stray\n' >"$EXTRA/stray-9.apk"
expect_fail_with "stray-9.apk is not listed in deps.lst" build
[ "$(listing "$PKG")" = "$before" ] || fail "a stray package changed packages/"
rm -f -- "$EXTRA/stray-9.apk"

# two pins of one package: an error that names both files, nothing changed
cp "$SCRATCH/deps.lst" "$SCRATCH/deps-twice.lst"
printf 'extra %s dl/extra/foo-2.1-r1.apk https://example.invalid/x\n' "$(sum "$EXTRA/foo-2.0-r1.apk")" \
    >>"$SCRATCH/deps-twice.lst"
err=$(DEPS=$SCRATCH/deps-twice.lst build 2>&1 || true)
grep -qF "pins foo twice: foo-2.0-r1.apk and foo-2.1-r1.apk" <<<"$err" ||
    fail "two pins of foo did not stop the build with both names: $err"
[ "$(listing "$PKG")" = "$before" ] || fail "two pins changed packages/"
# a pinned name that does not read as name-version is refused too
cp "$SCRATCH/deps.lst" "$SCRATCH/deps-odd.lst"
printf 'extra %s dl/extra/odd.apk https://example.invalid/x\n' "$(sum "$EXTRA/foo-2.0-r1.apk")" \
    >>"$SCRATCH/deps-odd.lst"
err=$(DEPS=$SCRATCH/deps-odd.lst build 2>&1 || true)
grep -qF "odd.apk in deps.lst does not read as name-version.apk" <<<"$err" ||
    fail "an unreadable pinned name was accepted: $err"

# R12d: a package file without the scan line stops the build before packages/ changes, with no image
grep -v -e --network-scan "$FIX/fake-qmi.sh" >"$SCRATCH/no-scan.sh"
FAKE_QMI_SH=$SCRATCH/no-scan.sh expect_fail_with "qmi.sh of uqmi-1.0-r1.apk has 0 lines with --network-scan" build
[ "$(listing "$PKG")" = "$before" ] || fail "a missing scan line changed packages/"
[ -z "$(find "$I" -name '*.bin')" ] || fail "a missing scan line left an image"

# the right set: earlier versions of the pinned packages go by exact package name, the rest stays
expect_fail_with "ImageBuilder produced no sysupgrade image" build
for f in "${PINNED[@]}"; do
    cmp -s "$EXTRA/$f" "$PKG/$f" || fail "$f was not copied into packages/"
done
for f in "${GONE[@]}"; do
    [ ! -e "$PKG/$f" ] || fail "earlier version $f is still in packages/"
done
for f in "${STAY[@]}"; do
    [ "$(cat "$PKG/$f")" = "ib $f" ] || fail "the ImageBuilder's $f was removed or changed"
done
want=$((${#PINNED[@]} + ${#STAY[@]}))
[ "$(listing "$PKG" | wc -l)" = "$want" ] || fail "packages/ holds unexpected files: $(listing "$PKG" | tr '\n' ' ')"

# R12d: after make image, an image file that is not this build's package file minus the scan line
# (the feed changed between the fetch and make image) stops the build, with no image
sed 's/sleep 3/sleep 4/' "$FIX/fake-qmi.sh" >"$SCRATCH/other-orig.sh"
FAKE_QMI_ORIG=$SCRATCH/other-orig.sh expect_fail_with "is not the package's file minus its scan line" build
[ -z "$(find "$I" -name '*.bin')" ] || fail "a changed package file left an image"

# the real list: every file it pins for the group is a plain name under dl/extra that reads as
# name-version, and no package is pinned twice
names=()
while read -r group _ path _; do
    [ "$group" = extra ] || continue
    [[ $path == dl/extra/*.apk ]] || fail "deps.lst pins $path in the group extra outside dl/extra"
    names+=("$(bash -c 'source "$1"; apk_name "$2"' _ "$FW/pinned-packages.sh" "$path")")
done < <(grep -v '^[[:space:]]*#' "$FW/deps.lst")
for nm in "${names[@]}"; do [ -n "$nm" ] || fail "deps.lst pins an .apk whose name does not parse"; done
[ "$(printf '%s\n' "${names[@]}" | sort | uniq -d | wc -l)" = 0 ] || fail "deps.lst pins a package twice"
echo ok
