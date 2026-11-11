#!/usr/bin/env bash
# SPEC R12d, D82: the image's /lib/netifd/proto/qmi.sh is the uqmi package's file minus its one
# network-scan line. qmi-handler.sh runs here against a stand-in apk and a made-up handler file:
#   - one scan line: the derived file is the package file minus exactly that line, mode 0755, in
#     0755 directories, and passes sh -n;
#   - no scan line, or two: the derivation stops, names the package file and writes nothing;
#   - a derived file that fails sh -n stops the derivation;
#   - a lost network (update, fetch or unpack fails) stops it with the reason;
#   - qmi_verify accepts a final rootfs that equals the pristine file minus the line, and stops on
#     a final rootfs that still has the scan, differs elsewhere, has another file mode, or has no
#     pristine tree to check.
# build.sh's own call (no image when the line is missing) is covered by 15-pinned-packages.sh and
# 60-images.sh. Nothing here is OpenWrt's file.
# shellcheck source=tests/build/lib.bash
source "$(dirname "$0")/lib.bash"
scratch qmi
# shellcheck disable=SC2034  # read by qmi_sh_n in qmi-handler.sh
LW_ROOTFS=$FW/work/dl/x86/rootfs
die() {
    echo "test: error: $*" >&2
    exit 1
}
# shellcheck source=qmi-handler.sh
source "$FW/qmi-handler.sh"

IB=$SCRATCH/ib
fake_qmi_ib "$IB"
export FAKE_QMI_SH=$SCRATCH/pkg-qmi.sh
OUT_FILE=$SCRATCH/overlay/$QMI_SH_REL

# derive: a fresh overlay and work dir; stdout is the package name, stderr the reason
derive() {
    rm -rf -- "$SCRATCH/overlay" "$SCRATCH/work"
    mkdir -p "$SCRATCH/overlay"
    (qmi_derive "$IB" "$SCRATCH/overlay" "$SCRATCH/work")
}

# one scan line
cp "$FIX/fake-qmi.sh" "$FAKE_QMI_SH"
[ "$(derive)" = uqmi-1.0-r1.apk ] || fail "the derivation did not name the package"
[ "$(grep -c -e --network-scan "$FAKE_QMI_SH")" = 1 ] || fail "the fixture has not exactly one scan line"
want=$(grep -v -e --network-scan "$FAKE_QMI_SH")
[ "$(cat "$OUT_FILE")" = "$want" ] || fail "the derived file is not the fixture minus the scan line"
[ "$(diff "$FAKE_QMI_SH" "$OUT_FILE" | grep -c '^[<>]')" = 1 ] || fail "more than one line differs"
grep -q -e --set-network-modes "$OUT_FILE" || fail "the mode set was dropped"
[ "$(stat -c %a "$OUT_FILE")" = 755 ] || fail "qmi.sh is not 0755"
[ "$(stat -c %a "$SCRATCH/overlay/lib" "$SCRATCH/overlay/lib/netifd" "$SCRATCH/overlay/lib/netifd/proto" |
    sort -u)" = 755 ] || fail "the directories of qmi.sh are not 0755"

# no scan line, and two
grep -v -e --network-scan "$FIX/fake-qmi.sh" >"$FAKE_QMI_SH"
expect_fail_with "uqmi-1.0-r1.apk has 0 lines with --network-scan, expected exactly 1" derive
[ ! -e "$OUT_FILE" ] || fail "a missing scan line still wrote qmi.sh"
{
    cat "$FIX/fake-qmi.sh"
    grep -e --network-scan "$FIX/fake-qmi.sh"
} >"$FAKE_QMI_SH"
expect_fail_with "/lib/netifd/proto/qmi.sh of uqmi-1.0-r1.apk has 2 lines with --network-scan" derive
[ ! -e "$OUT_FILE" ] || fail "two scan lines still wrote qmi.sh"

# the derived file must parse
{
    cat "$FIX/fake-qmi.sh"
    echo 'if then fi ('
} >"$FAKE_QMI_SH"
expect_fail_with "fails sh -n" derive
[ ! -e "$OUT_FILE" ] || fail "a file that fails sh -n was written"

# a lost network, at each step
cp "$FIX/fake-qmi.sh" "$FAKE_QMI_SH"
for step in update fetch extract; do
    export FAKE_APK_FAIL=$step
    case $step in
    extract) msg="cannot unpack uqmi-1.0-r1.apk" ;;
    *) msg="(network?)" ;;
    esac
    expect_fail_with "$msg" derive
    [ ! -e "$OUT_FILE" ] || fail "a failed $step still wrote qmi.sh"
done
unset FAKE_APK_FAIL

# qmi_verify: the ImageBuilder's final rootfs against the pristine package rootfs
BD=$IB/build_dir/target-fake
verify() { (qmi_verify "$IB"); }
mkdir -p "$BD/root.orig-fake/$(dirname "$QMI_SH_REL")" "$BD/root-fake/$(dirname "$QMI_SH_REL")"
cp "$FIX/fake-qmi.sh" "$BD/root.orig-fake/$QMI_SH_REL"
grep -v -e --network-scan "$FIX/fake-qmi.sh" >"$BD/root-fake/$QMI_SH_REL"
verify || fail "a correct final rootfs was refused"
chmod 0700 "$BD/root-fake/$QMI_SH_REL"
expect_fail_with "does not have the package file's mode" verify
cp "$FIX/fake-qmi.sh" "$BD/root-fake/$QMI_SH_REL"
expect_fail_with "is not the package's file minus its scan line" verify
{
    grep -v -e --network-scan "$FIX/fake-qmi.sh"
    echo '# one more line'
} >"$BD/root-fake/$QMI_SH_REL"
expect_fail_with "is not the package's file minus its scan line" verify
grep -v -e --network-scan "$FIX/fake-qmi.sh" >"$BD/root.orig-fake/$QMI_SH_REL"
expect_fail_with "has 0 lines with --network-scan, expected 1" verify
mv "$BD/root.orig-fake" "$BD/gone"
expect_fail_with "no root.orig-*" verify
echo ok
