#!/usr/bin/env bash
# SPEC R14b, R14c, D195: the image's /usr/bin/watchcat.sh and /etc/init.d/watchcat are the watchcat
# package's files with the edits of watchcat-handler.sh (three one-line additions to the worker, two to
# the init script) and no other change. The handler runs here against a stand-in apk and made-up
# package files whose sha256 are the pins of the run (LW_WATCHCAT_SHA256, LW_WATCHCAT_INIT_SHA256,
# which work only under the test suite, R12g):
#   - the good case: only lines added, every upstream line and its notice kept, mode 0755 in 0755
#     directories, passes sh -n, and the repository holds no copy of either package file;
#   - another sha256 than the pin, for either file, stops the derivation and writes nothing;
#   - each of the five anchors missing or doubled: it stops, names the package file and the anchor, and
#     writes nothing; so does a result that fails sh -n;
#   - a lost network stops it with the reason;
#   - wc_verify accepts a final rootfs that equals the pristine files with the edits and stops on one
#     that differs, has another mode, a pristine file of another sha256, or no pristine tree.
# Nothing here is OpenWrt's file.
# shellcheck disable=SC2034  # the pins are read by wc_transform in watchcat-handler.sh
# shellcheck source=tests/build/lib.bash
source "$(dirname "$0")/lib.bash"
scratch watchcat
# shellcheck disable=SC2034  # read by qmi_sh_n in qmi-handler.sh
LW_ROOTFS=$FW/work/dl/x86/rootfs
die() {
    echo "test: error: $*" >&2
    exit 1
}
# shellcheck source=qmi-handler.sh
source "$FW/qmi-handler.sh"
# shellcheck source=watchcat-handler.sh
source "$FW/watchcat-handler.sh"

IB=$SCRATCH/ib
fake_qmi_ib "$IB"
OUT_SH=$SCRATCH/overlay/$WC_SH_REL
OUT_INIT=$SCRATCH/overlay/$WC_INIT_REL
SH=$SCRATCH/pkg-watchcat.sh
INIT=$SCRATCH/pkg-watchcat-init
# what the stand-in apk extracts
export FAKE_WC_SH=$SH FAKE_WC_INIT=$INIT

# pin SH INIT: the pins of this run are these files'
pin() {
    WC_STOCK_SHA256=$(sha256sum "$1" | cut -d' ' -f1)
    WC_INIT_STOCK_SHA256=$(sha256sum "$2" | cut -d' ' -f1)
}
# derive: a fresh overlay and work dir; stdout is the package name, stderr the reason
derive() {
    trash_dirs "$SCRATCH/overlay" "$SCRATCH/work"
    mkdir -p "$SCRATCH/overlay"
    (wc_derive "$IB" "$SCRATCH/overlay" "$SCRATCH/work")
}
trash_dirs() { rm -r -f -- "$@"; }
nothing() { [ ! -e "$OUT_SH" ] && [ ! -e "$OUT_INIT" ] || fail "$1 still wrote a file"; }
# only_added STOCK DERIVED N: DERIVED has every line of STOCK in its order and N lines more
only_added() {
    local removed added
    removed=$(diff "$1" "$2" | grep -c '^<' || true)
    added=$(diff "$1" "$2" | grep -c '^>' || true)
    [ "$removed" = 0 ] || fail "a line of $1 was changed or dropped"
    [ "$added" = "$3" ] || fail "$2 has $added lines more than $1, expected $3"
}

# the good case
cp "$FIX/fake-watchcat.sh" "$SH"
cp "$FIX/fake-watchcat-init" "$INIT"
pin "$SH" "$INIT"
[ "$(derive)" = watchcat-1.0-r1.apk ] || fail "the derivation did not name the package"
only_added "$SH" "$OUT_SH" 3
only_added "$INIT" "$OUT_INIT" 2
grep -qxF '# Copyright (C) made-up notice of the fixture' "$OUT_SH" || fail "the upstream notice was dropped"
grep -qxF '# Copyright (C) made-up notice of the fixture' "$OUT_INIT" || fail "the upstream notice of the init script was dropped"
# each added line next to its anchor (R14b)
[ "$(grep -xF -A1 -e "$WC_A_LIB" "$OUT_SH" | tail -n 1)" = "$WC_N_LIB" ] || fail "the hook is not loaded after the stock libraries"
[ "$(grep -xF -A1 -e "$WC_A_HOSTS" "$OUT_SH" | tail -n 1)" = "$WC_N_HOSTS" ] || fail "the host list is not emptied after the stock line"
[ "$(grep -xF -B1 -e "$WC_A_TIMER" "$OUT_SH" | head -n 1)" = "$WC_N_TIMER" ] || fail "the round does not run before the timer test"
[ "$(grep -xF -A1 -e "$WC_A_OPT" "$OUT_INIT" | tail -n 1)" = "$WC_N_OPT" ] || fail "the option is not read after the stock options"
[ "$(grep -xF -A1 -e "$WC_A_ENV" "$OUT_INIT" | tail -n 1)" = "$WC_N_ENV" ] || fail "the variable is not set after the restart_iface command"
# the host loop of the reboot mode is the stock one: the edit is in the monitor function only
[ "$(grep -c 'LW_WATCHCAT_FAMILY' "$OUT_SH")" = 3 ] || fail "the hook variable is not used exactly three times"
[ "$(stat -c %a "$OUT_SH" "$OUT_INIT" | sort -u)" = 755 ] || fail "the files are not 0755"
[ "$(stat -c %a "$SCRATCH/overlay/usr" "$SCRATCH/overlay/usr/bin" "$SCRATCH/overlay/etc" "$SCRATCH/overlay/etc/init.d" |
    sort -u)" = 755 ] || fail "the directories are not 0755"
qmi_sh_n "$OUT_SH" || fail "the derived worker fails sh -n"
qmi_sh_n "$OUT_INIT" || fail "the derived init script fails sh -n"
cp "$OUT_SH" "$SCRATCH/good.sh"
cp "$OUT_INIT" "$SCRATCH/good-init"

# R14c: the repository holds no copy of the package's files: no tracked file has their notices
if git -C "$FW" rev-parse --git-dir >/dev/null 2>&1; then
    if git -C "$FW" grep --untracked -lE 'segal\.di\.ubi\.pt|nbembedded\.com' -- . ':!tests/build/46-watchcat-handler.sh' | grep -q .; then
        fail "R14c: a tracked file holds the notice of watchcat's upstream files"
    fi
fi

# another sha256 than the pin, either file
pin "$SH" "$INIT"
WC_STOCK_SHA256=0000000000000000000000000000000000000000000000000000000000000000
expect_fail_with "/usr/bin/watchcat.sh of watchcat-1.0-r1.apk has sha256 " derive
expect_fail_with "SPEC R14c" derive
nothing "a worker of another sha256"
pin "$SH" "$INIT"
WC_INIT_STOCK_SHA256=0000000000000000000000000000000000000000000000000000000000000000
expect_fail_with "/etc/init.d/watchcat of watchcat-1.0-r1.apk has sha256 " derive
nothing "an init script of another sha256"

# each anchor missing and doubled; the pins follow the edited file, so only the anchor can stop it
for a in LIB HOSTS TIMER; do
    var=WC_A_$a
    line=${!var}
    grep -vxF -e "$line" "$FIX/fake-watchcat.sh" >"$SH"
    cp "$FIX/fake-watchcat-init" "$INIT"
    pin "$SH" "$INIT"
    expect_fail_with "watchcat.sh of watchcat-1.0-r1.apk has 0 lines equal to the anchor" derive
    nothing "a missing $a anchor"
    {
        cat "$FIX/fake-watchcat.sh"
        printf '%s\n' "$line"
    } >"$SH"
    pin "$SH" "$INIT"
    expect_fail_with "watchcat.sh of watchcat-1.0-r1.apk has 2 lines equal to the anchor" derive
    nothing "a doubled $a anchor"
done
for a in OPT ENV; do
    var=WC_A_$a
    line=${!var}
    cp "$FIX/fake-watchcat.sh" "$SH"
    grep -vxF -e "$line" "$FIX/fake-watchcat-init" >"$INIT"
    pin "$SH" "$INIT"
    expect_fail_with "watchcat of watchcat-1.0-r1.apk has 0 lines equal to the anchor" derive
    nothing "a missing $a anchor"
    {
        cat "$FIX/fake-watchcat-init"
        printf '%s\n' "$line"
    } >"$INIT"
    pin "$SH" "$INIT"
    expect_fail_with "watchcat of watchcat-1.0-r1.apk has 2 lines equal to the anchor" derive
    nothing "a doubled $a anchor"
done

# the derived files must parse
cp "$FIX/fake-watchcat-init" "$INIT"
{
    cat "$FIX/fake-watchcat.sh"
    echo 'if then fi ('
} >"$SH"
pin "$SH" "$INIT"
expect_fail_with "fails sh -n" derive
nothing "a worker that fails sh -n"

# a lost network, at each step
cp "$FIX/fake-watchcat.sh" "$SH"
pin "$SH" "$INIT"
for step in update fetch extract; do
    export FAKE_APK_FAIL=$step
    case $step in
    extract) msg="cannot unpack watchcat-1.0-r1.apk" ;;
    *) msg="(network?)" ;;
    esac
    expect_fail_with "$msg" derive
    nothing "a failed $step"
done
unset FAKE_APK_FAIL

# wc_verify: the ImageBuilder's final rootfs against the pristine package rootfs
BD=$IB/build_dir/target-fake
verify() { (wc_verify "$IB"); }
mkdir -p "$BD/root.orig-fake/usr/bin" "$BD/root.orig-fake/etc/init.d" "$BD/root-fake/usr/bin" "$BD/root-fake/etc/init.d"
cp "$FIX/fake-watchcat.sh" "$BD/root.orig-fake/$WC_SH_REL"
cp "$FIX/fake-watchcat-init" "$BD/root.orig-fake/$WC_INIT_REL"
pin "$FIX/fake-watchcat.sh" "$FIX/fake-watchcat-init"
cp "$SCRATCH/good.sh" "$BD/root-fake/$WC_SH_REL"
cp "$SCRATCH/good-init" "$BD/root-fake/$WC_INIT_REL"
chmod 0755 "$BD/root.orig-fake/$WC_SH_REL" "$BD/root.orig-fake/$WC_INIT_REL" \
    "$BD/root-fake/$WC_SH_REL" "$BD/root-fake/$WC_INIT_REL"
verify || fail "a correct final rootfs was refused"
chmod 0700 "$BD/root-fake/$WC_INIT_REL"
expect_fail_with "does not have the package file's mode" verify
chmod 0755 "$BD/root-fake/$WC_INIT_REL"
cp "$FIX/fake-watchcat.sh" "$BD/root-fake/$WC_SH_REL"
expect_fail_with "is not the package's file with the edits of R14b" verify
cp "$SCRATCH/good.sh" "$BD/root-fake/$WC_SH_REL"
{
    cat "$SCRATCH/good-init"
    echo '# one more line'
} >"$BD/root-fake/$WC_INIT_REL"
expect_fail_with "is not the package's file with the edits of R14b" verify
cp "$SCRATCH/good-init" "$BD/root-fake/$WC_INIT_REL"
chmod 0755 "$BD/root-fake/$WC_INIT_REL"
sed 's/fake ping/fake ping again/' "$FIX/fake-watchcat.sh" >"$BD/root.orig-fake/$WC_SH_REL"
expect_fail_with "has sha256 " verify
mv "$BD/root.orig-fake" "$BD/gone"
expect_fail_with "no root.orig-*" verify
echo ok
