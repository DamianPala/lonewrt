#!/usr/bin/env bash
# SPEC R12d to R12f, D82, D172, D192: the image's /lib/netifd/proto/qmi.sh is the uqmi package's file
# with the edits of qmi-handler.sh (the negotiation block replaced by qmi-edits/call.sh, the functions
# of qmi-edits/functions.sh in front of the teardown function, the repair before the registration,
# three one-line changes and the network-scan line dropped). qmi-handler.sh runs here against a
# stand-in apk and a made-up handler file whose sha256 is the pin of the run (LW_QMI_SHA256):
#   - the good case: every edit made once at its place, the upstream notice kept, mode 0755 in 0755
#     directories, passes sh -n;
#   - another sha256 than the pin stops the derivation and writes nothing;
#   - each anchor missing, doubled, or the end before the start: the derivation stops, names the
#     package file and the anchor and writes nothing; so do no scan line, two, and a file that fails
#     sh -n;
#   - a lost network (update, fetch or unpack fails) stops it with the reason;
#   - qmi_verify accepts a final rootfs that equals the pristine file with the edits, and stops on a
#     final rootfs that differs, has another file mode, a pristine file of another sha256, or has no
#     pristine tree to check.
# build.sh's own call (no image when an anchor is missing) is covered by 15-pinned-packages.sh and
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
LW_QMI_SHA256=$(sha256sum "$FIX/fake-qmi.sh" | cut -d' ' -f1)
export LW_QMI_SHA256
# shellcheck source=qmi-handler.sh
source "$FW/qmi-handler.sh"

IB=$SCRATCH/ib
fake_qmi_ib "$IB"
export FAKE_QMI_SH=$SCRATCH/pkg-qmi.sh
OUT_FILE=$SCRATCH/overlay/$QMI_SH_REL

# pin FILE: the sha256 pin of this run is FILE's
pin() { QMI_STOCK_SHA256=$(sha256sum "$1" | cut -d' ' -f1); }

# derive: a fresh overlay and work dir; stdout is the package name, stderr the reason
derive() {
    rm -rf -- "$SCRATCH/overlay" "$SCRATCH/work"
    mkdir -p "$SCRATCH/overlay"
    (qmi_derive "$IB" "$SCRATCH/overlay" "$SCRATCH/work")
}

# the good case
cp "$FIX/fake-qmi.sh" "$FAKE_QMI_SH"
pin "$FAKE_QMI_SH"
[ "$(derive)" = uqmi-1.0-r1.apk ] || fail "the derivation did not name the package"
[ "$(grep -c -e --network-scan "$FAKE_QMI_SH")" = 1 ] || fail "the fixture has not exactly one scan line"
grep -q -e --network-scan "$OUT_FILE" && fail "the scan line is still there"
grep -qxF '# Copyright (C) made-up notice of the fixture' "$OUT_FILE" || fail "the upstream notice was dropped"
grep -qxF '		# scan' "$OUT_FILE" || fail "the comment above the scan line was dropped"
grep -q -e --set-network-modes "$OUT_FILE" || fail "the mode set was dropped"
grep -qxF '	fake start' "$OUT_FILE" && fail "the stock negotiation block is still there"
for l in '	lw_negotiate || return 1' '	lw_repair' '	echo "Setting up $ifname"'; do
    [ "$(grep -cxF -e "$l" "$OUT_FILE")" = 1 ] || fail "'$l' is not there exactly once"
done
[ "$(grep -c '^lw_negotiate()' "$OUT_FILE")" = 1 ] || fail "qmi-edits/functions.sh is not in the file"
[ "$(grep -n '^lw_negotiate()' "$OUT_FILE" | cut -d: -f1)" -lt "$(grep -n '^qmi_wds_stop() {' "$OUT_FILE" | cut -d: -f1)" ] ||
    fail "the functions are not in front of the teardown function"
[ "$(grep -n '^	lw_repair$' "$OUT_FILE" | cut -d: -f1)" -lt "$(grep -n 'network-register' "$OUT_FILE" | cut -d: -f1)" ] ||
    fail "the repair is not before the registration call"
grep -qxF '			[ -n "$pdh_4" ] && json_add_string iface_464xlat "0"' "$OUT_FILE" || fail "464XLAT line not changed"
grep -qxF '		if { [ -z "$dhcpv6" ] || [ "$dhcpv6" = 0 ]; } && lw_v6_ok; then' "$OUT_FILE" || fail "IPv6 settings line not changed"
[ "$(grep -cxF '	[ -n "$pdh_4" ] && {' "$OUT_FILE")" = 1 ] || fail "the publish block (before the IPv6 branch) was changed"
[ "$(grep -cxF '	[ -z "$pdh_4" ] || {' "$OUT_FILE")" = 1 ] || fail "the IPv4 child block was not changed"
[ "$(stat -c %a "$OUT_FILE")" = 755 ] || fail "qmi.sh is not 0755"
[ "$(stat -c %a "$SCRATCH/overlay/lib" "$SCRATCH/overlay/lib/netifd" "$SCRATCH/overlay/lib/netifd/proto" |
    sort -u)" = 755 ] || fail "the directories of qmi.sh are not 0755"
qmi_sh_n "$OUT_FILE" || fail "the derived file fails sh -n"
GOOD=$SCRATCH/good-qmi.sh
cp "$OUT_FILE" "$GOOD"

# another sha256 than the pin
# shellcheck disable=SC2034  # read by qmi_transform in qmi-handler.sh
QMI_STOCK_SHA256=0000000000000000000000000000000000000000000000000000000000000000
expect_fail_with "uqmi-1.0-r1.apk has sha256 " derive
expect_fail_with "SPEC R12e" derive
[ ! -e "$OUT_FILE" ] || fail "a file of another sha256 still wrote qmi.sh"

# each anchor missing and doubled; the pin follows the edited fixture, so only the anchor can stop it
anchors=(NEG_START NEG_END FUNCS REGISTER 464 V6)
for a in "${anchors[@]}"; do
    var=QMI_A_$a
    line=${!var}
    grep -vxF -e "$line" "$FIX/fake-qmi.sh" >"$FAKE_QMI_SH"
    pin "$FAKE_QMI_SH"
    expect_fail_with "has 0 lines equal to the anchor" derive
    [ ! -e "$OUT_FILE" ] || fail "a missing $a anchor still wrote qmi.sh"
    {
        cat "$FIX/fake-qmi.sh"
        printf '%s\n' "$line"
    } >"$FAKE_QMI_SH"
    pin "$FAKE_QMI_SH"
    expect_fail_with "has 2 lines equal to the anchor" derive
    [ ! -e "$OUT_FILE" ] || fail "a doubled $a anchor still wrote qmi.sh"
done
# the IPv4 child block: only the one after the IPv6 settings branch counts
awk -v a="$QMI_A_V4" '$0 == a { n++; if (n == 2) next } { print }' "$FIX/fake-qmi.sh" >"$FAKE_QMI_SH"
pin "$FAKE_QMI_SH"
expect_fail_with "the anchor IPv4 child block after the IPv6 settings branch" derive
{
    cat "$FIX/fake-qmi.sh"
    printf '%s\n' "$QMI_A_V4"
} >"$FAKE_QMI_SH"
pin "$FAKE_QMI_SH"
expect_fail_with "the anchor IPv4 child block after the IPv6 settings branch" derive
# the end of the negotiation before its start
awk -v s="$QMI_A_NEG_START" -v e="$QMI_A_NEG_END" \
    '$0 == s { print e; next } $0 == e { print s; next } { print }' "$FIX/fake-qmi.sh" >"$FAKE_QMI_SH"
pin "$FAKE_QMI_SH"
expect_fail_with "has the end of the negotiation before its start" derive
[ ! -e "$OUT_FILE" ] || fail "reversed anchors still wrote qmi.sh"

# no scan line, and two
grep -v -e --network-scan "$FIX/fake-qmi.sh" >"$FAKE_QMI_SH"
pin "$FAKE_QMI_SH"
expect_fail_with "uqmi-1.0-r1.apk has 0 lines with --network-scan, expected exactly 1" derive
[ ! -e "$OUT_FILE" ] || fail "a missing scan line still wrote qmi.sh"
{
    cat "$FIX/fake-qmi.sh"
    grep -e --network-scan "$FIX/fake-qmi.sh"
} >"$FAKE_QMI_SH"
pin "$FAKE_QMI_SH"
expect_fail_with "/lib/netifd/proto/qmi.sh of uqmi-1.0-r1.apk has 2 lines with --network-scan" derive
[ ! -e "$OUT_FILE" ] || fail "two scan lines still wrote qmi.sh"

# the derived file must parse
{
    cat "$FIX/fake-qmi.sh"
    echo 'if then fi ('
} >"$FAKE_QMI_SH"
pin "$FAKE_QMI_SH"
expect_fail_with "fails sh -n" derive
[ ! -e "$OUT_FILE" ] || fail "a file that fails sh -n was written"

# a lost network, at each step
cp "$FIX/fake-qmi.sh" "$FAKE_QMI_SH"
pin "$FAKE_QMI_SH"
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
pin "$FIX/fake-qmi.sh"
cp "$GOOD" "$BD/root-fake/$QMI_SH_REL"
chmod 0755 "$BD/root.orig-fake/$QMI_SH_REL" "$BD/root-fake/$QMI_SH_REL"
verify || fail "a correct final rootfs was refused"
chmod 0700 "$BD/root-fake/$QMI_SH_REL"
expect_fail_with "does not have the package file's mode" verify
cp "$FIX/fake-qmi.sh" "$BD/root-fake/$QMI_SH_REL"
expect_fail_with "is not the package's file with the edits of R12d" verify
{
    cat "$GOOD"
    echo '# one more line'
} >"$BD/root-fake/$QMI_SH_REL"
expect_fail_with "is not the package's file with the edits of R12d" verify
cp "$GOOD" "$BD/root-fake/$QMI_SH_REL"
chmod 0755 "$BD/root-fake/$QMI_SH_REL"
sed 's/sleep 3/sleep 4/' "$FIX/fake-qmi.sh" >"$BD/root.orig-fake/$QMI_SH_REL"
expect_fail_with "has sha256 " verify
mv "$BD/root.orig-fake" "$BD/gone"
expect_fail_with "no root.orig-*" verify
echo ok
