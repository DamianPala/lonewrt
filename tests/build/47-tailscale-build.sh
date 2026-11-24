#!/usr/bin/env bash
# SPEC R63 to R63g, R64b: what build.sh does for a tailscale image, against a stand-in ImageBuilder (a
# Makefile that records its PACKAGES and FILES and writes a sysupgrade tar with a root file of a
# chosen size and a manifest) and the stand-in apk of fixtures/fake-apk, so it takes seconds and
# needs no network:
#   - the packages tailscale and kmod-tun go to make for a tailscale profile and for no other;
#   - /etc/lw-build of a tailscale image gets the line tailscale=<package version> (R63b), another
#     image keeps its four lines, and the overlay of the other image holds no Tailscale file;
#   - the key file is 0600 (R64b);
#   - a root file system of 15 500 000 bytes passes, one byte more stops the build with no new
#     image (R63a), and only for a tailscale image;
#   - a package version other than 1.104.1 builds with a warning that names it, a revision of
#     1.104.1 and 1.104.10 are told apart (R63g);
#   - a feed without the package, or a manifest that does not have the version the overlay was
#     given, stops the build.
# shellcheck source=tests/build/lib.bash
source "$(dirname "$0")/lib.bash"
scratch tsbuild
W=$SCRATCH/work
P=$SCRATCH/profiles
I=$SCRATCH/image
EXTRA=$W/dl/extra
make_profiles "$P"
# no R3a warning about loose files to tell apart from the ones under test
chmod 600 "$P"/*.conf "$P"/fake-full/dropbear_*
mkdir -p "$EXTRA" "$W/ib/packages" "$I"
fake_qmi_ib "$W/ib"
printf 'fake foo\n' >"$EXTRA/foo-2.0-r1.apk"
echo "extra $(sha256sum "$EXTRA/foo-2.0-r1.apk" | cut -d' ' -f1) dl/extra/foo-2.0-r1.apk https://example.invalid/x" \
    >"$SCRATCH/deps.lst"
fake_make_image >"$W/ib/Makefile"
sed 's/^@@/\t/' >>"$W/ib/Makefile" <<'EOF'
@@mkdir -p $(FAKE_LOG)/files && cp -a $(FILES)/. $(FAKE_LOG)/files/
@@printf '%s\n' '$(PACKAGES)' >$(FAKE_LOG)/packages
@@mkdir -p $(BIN_DIR)/sysupgrade-fake
@@truncate -s $(FAKE_ROOT_SIZE) $(BIN_DIR)/sysupgrade-fake/root
@@echo kernel >$(BIN_DIR)/sysupgrade-fake/kernel
@@tar -C $(BIN_DIR) -cf $(BIN_DIR)/fake-$(EXTRA_IMAGE_NAME)-x-squashfs-sysupgrade.bin sysupgrade-fake
@@printf 'base-files - 1\n' >$(BIN_DIR)/fake-$(EXTRA_IMAGE_NAME)-x.manifest
@@[ -z "$(FAKE_TS_MANIFEST)" ] || printf 'tailscale - %s\n' '$(FAKE_TS_MANIFEST)' >>$(BIN_DIR)/fake-$(EXTRA_IMAGE_NAME)-x.manifest
EOF

export FAKE_QMI_SH=$FIX/fake-qmi.sh
LW_QMI_SHA256=$(sha256sum "$FAKE_QMI_SH" | cut -d" " -f1)
export LW_QMI_SHA256
fake_wc_pins
fake_odhcpd_pin
# the defaults of a good tailscale build: the feed and the manifest agree, the root is small
export FAKE_ROOT_SIZE=14397440 FAKE_TS_MANIFEST=1.104.1-r1
unset FAKE_TS_FEED FAKE_APK_FAIL
n=0
# newlog: a new folder for what the next build's make records; called in this shell, because a build
# run inside $( ) could not hand the folder back
newlog() {
    n=$((n + 1))
    FAKE_LOG=$SCRATCH/log-$n
    export FAKE_LOG
    mkdir -p "$FAKE_LOG"
}
# tsbuild PROFILE: one build into the scratch image/
tsbuild() {
    LW_WORK=$W LW_ROOTFS=$FW/work/dl/x86/rootfs LW_DEPS_LIST=$SCRATCH/deps.lst LW_PROFILES=$P \
        LW_IMAGE=$I "$FW/build.sh" "$@"
}
# the sorted package names of a list: PACKAGES, and the removals of REMOVED_PACKAGES as -name (D167)
base_packages() {
    {
        sed -n '/^PACKAGES=(/,/^)/p' "$FW/build.sh" | sed '1d;$d' | tr ' ' '\n' | sed '/^$/d'
        sed -n 's/^REMOVED_PACKAGES=(\(.*\))$/\1/p' "$FW/build.sh" | tr ' ' '\n' | sed '/^$/d;s/^/-/'
    } | sort
}
sent_packages() { tr ' ' '\n' <"$FAKE_LOG/packages" | sed '/^$/d' | sort; }

# a profile without Tailscale: the base packages, four lines in /etc/lw-build, no Tailscale file, and
# no limit on the root file system (R63a is for a tailscale image), no query of the feed
newlog
FAKE_ROOT_SIZE=20000000 FAKE_TS_FEED='' FAKE_APK_FAIL=list tsbuild generic >/dev/null 2>&1 ||
    fail "a profile without Tailscale needed the tailscale package, or was held to its size limit"
[ "$(sent_packages)" = "$(base_packages)" ] || fail "R63: packages of an image without Tailscale: $(sent_packages | tr '\n' ' ')"
! sent_packages | grep -qE '^(tailscale|kmod-tun)$' || fail "R63: an image without Tailscale asked for tailscale or kmod-tun"
[ "$(wc -l <"$FAKE_LOG/files/etc/lw-build")" = 4 ] || fail "R63b: /etc/lw-build of an image without Tailscale is not four lines"
! grep -q '^tailscale=' "$FAKE_LOG/files/etc/lw-build" || fail "R63b: an image without Tailscale has a tailscale= line"
[ -z "$(find "$FAKE_LOG/files" -ipath '*tailscale*')" ] || fail "R63: the overlay of an image without Tailscale has a tailscale path"

# a tailscale profile: the two packages besides the base set, the version line, the key file
newlog
err=$(tsbuild fake-full 2>&1 >/dev/null) || fail "a tailscale image did not build: $err"
[ "$(sent_packages)" = "$({ base_packages; printf '%s\n' tailscale kmod-tun; } | sort)" ] ||
    fail "R63: packages of a tailscale image: $(sent_packages | tr '\n' ' ')"
lw=$FAKE_LOG/files/etc/lw-build
[ "$(wc -l <"$lw")" = 5 ] || fail "R63b: /etc/lw-build of a tailscale image is not five lines"
[ "$(tail -n 1 "$lw")" = tailscale=1.104.1-r1 ] || fail "R63b: the last line of /etc/lw-build is not tailscale=1.104.1-r1: $(tail -n 1 "$lw")"
grep -qx "version=$(cat "$FW/VERSION")" "$lw" || fail "R3b: the version line of /etc/lw-build changed"
! grep -qi warning <<<"$err" || fail "a good tailscale image warned: $err"
key=$FAKE_LOG/files/etc/tailscale/lw-authkey
[ "$(stat -c %a "$key")" = 600 ] || fail "R64b: lw-authkey is not 0600 in the overlay make gets"
[ "$(cat "$key")" = "$FAKE_TS_AUTHKEY" ] || fail "R64b: lw-authkey is not the profile's key"
[ -f "$I/fake-full-sysupgrade.bin" ] || fail "a good tailscale build published no image"
! grep -qF "$FAKE_TS_AUTHKEY" <<<"$err" || fail "the build output shows the auth key"

# R63a: 15 500 000 bytes pass, one more stops the build with nothing new in image/
newlog
FAKE_ROOT_SIZE=15500000 tsbuild fake-full >/dev/null 2>&1 || fail "R63a: a root of 15 500 000 bytes was refused"
before=$(listing "$I")
newlog
FAKE_ROOT_SIZE=15500001 expect_fail_with "the root file system of the image is 15500001 bytes, over the limit of 15500000" \
    tsbuild fake-full
[ "$(listing "$I")" = "$before" ] || fail "R63a: a root over the limit changed image/: $(listing "$I")"

# R63g: a version the stand-in CLI was not made from builds with a warning that names it; another
# revision of 1.104.1 does not warn, and 1.104.10 is not 1.104.1
for v in 1.105.0-r1 1.104.10-r1 1.104.0-r3 2.0.0-r1; do
    newlog
    FAKE_TS_FEED=$v FAKE_TS_MANIFEST=$v tsbuild fake-full >/dev/null 2>"$SCRATCH/warn" || fail "R63g: version $v did not build"
    grep -q "^build: warning: .*tailscale package is $v" "$SCRATCH/warn" || fail "R63g: no warning for $v: $(cat "$SCRATCH/warn")"
    grep -qF 1.104.1 "$SCRATCH/warn" || fail "R63g: the warning for $v does not name the known version"
    [ "$(tail -n 1 "$FAKE_LOG/files/etc/lw-build")" = "tailscale=$v" ] || fail "R63b: lw-build lacks tailscale=$v"
done
for v in 1.104.1-r1 1.104.1-r7 1.104.1; do
    newlog
    FAKE_TS_FEED=$v FAKE_TS_MANIFEST=$v tsbuild fake-full >/dev/null 2>"$SCRATCH/warn" || fail "R63g: version $v did not build"
    ! grep -qi warning "$SCRATCH/warn" || fail "R63g: a warning for $v: $(cat "$SCRATCH/warn")"
done

# the feed and the manifest must agree, the manifest must have the package, the feed must know it
before=$(listing "$I")
newlog
FAKE_TS_MANIFEST=1.104.2-r1 expect_fail_with "the image has tailscale 1.104.2-r1 but /etc/lw-build says 1.104.1-r1" tsbuild fake-full
newlog
FAKE_TS_MANIFEST='' expect_fail_with "the manifest of the image has no tailscale package" tsbuild fake-full
newlog
FAKE_TS_FEED='' expect_fail_with "no tailscale package in the package feeds" tsbuild fake-full
newlog
FAKE_APK_FAIL=list expect_fail_with "no tailscale package in the package feeds" tsbuild fake-full
[ "$(listing "$I")" = "$before" ] || fail "a stopped tailscale build changed image/: $(listing "$I")"
echo ok
