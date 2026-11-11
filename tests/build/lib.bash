# Helpers for the host-side build tests (tests/build/[0-9][0-9]-*.sh), sourced by bash.
# Every test works on copies (LW_PROFILES, LW_SRC, LW_IMAGE) unless it builds the real generic image.
# shellcheck shell=bash disable=SC2034  # the variables are used by the tests that source this file
set -euo pipefail

FW="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT=$FW/tests/.out
FIX=$FW/tests/build/fixtures
RENDER=$OUT/render

LW_WORK=${LW_WORK:-$FW/work}

# Values of a private profile that must never reach the generic image (SPEC R4a): one per line in
# tests/build/private-values.txt, which git ignores; without the file the list is empty. The fake
# values below are the part of this check that the repo carries.
LW_VALUES=()
if [ -f "$FW/tests/build/private-values.txt" ]; then
    mapfile -t LW_VALUES < <(grep -v '^$' "$FW/tests/build/private-values.txt" || true)
fi
# The fake WireGuard private key is joined from two parts here and put into the fixture by
# make_profiles, so no file holds a whole private-key-shaped string for secret scanners to flag.
FAKE_WG_PRIVATE_KEY="RkFLRS13Zy1wcml2YXRl""LWtleS1xN3g5LTAxMjM0NTY=" # gitleaks:allow (synthetic)
# Values that only fixtures/fake-full.conf and fixtures/fake-full/ carry (SPEC R4, R4a)
FAKE_VALUES=(
    fakelw-q7x9 192.168.77.1 FakeLwSsid-q7x9 fake-wifi-key-q7x9 fakesaltq7x9 fake.apn.q7x9
    fakeuser-q7x9 fakepass-q7x9 "$FAKE_WG_PRIVATE_KEY"
    RkFLRS13Zy1wZWVyLXB1YmxpYy1rZXktcTd4OS0wMTI= 10.99.77. vpn.fake-q7x9.example
    FAKEauthorizedKEYq7x9 FAKE-dropbear-ed25519-host-key-q7x9 FAKE-dropbear-rsa-host-key-q7x9
    FAKEtgtokenq7x9 -1009977001977 hc-ping.fake-q7x9.example FAKEhcping-q7x9-0001
    +15550100123 15550100456
)

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# scratch NAME: a fresh directory under tests/.out, removed when the test exits
SCRATCH=
scratch() {
    mkdir -p "$OUT"
    SCRATCH=$(mktemp -d "$OUT/$1.XXXXXX")
    trap 'rm -rf -- "$SCRATCH"' EXIT
}

# make_profiles DIR: generic.conf from the repo plus the fake full fixture
make_profiles() {
    mkdir -p "$1"
    cp "$FW/profiles/generic.conf" "$1/"
    cp -r "$FIX/fake-full.conf" "$FIX/fake-full" "$1/"
    sed -i "s|@FAKE_WG_PRIVATE_KEY@|$FAKE_WG_PRIVATE_KEY|" "$1/fake-full.conf"
}

# listing DIR: every entry under DIR, hidden ones too, to prove a failed build added nothing
listing() {
    find "$1" -mindepth 1 -printf '%P %s\n' 2>/dev/null | sort
}

# assert_absent DIR VALUE...: no file under DIR contains any VALUE (binary files too)
assert_absent() {
    local dir=$1 value
    shift
    # one pass over the tree first (the ImageBuilder tree is about 1 GB), per value only on a hit
    grep -rqaF -f <(printf '%s\n' "$@") "$dir" || return 0
    for value in "$@"; do
        if grep -rlaF -- "$value" "$dir" >/dev/null; then
            fail "'$value' found in $dir: $(grep -rlaF -- "$value" "$dir" | head -n 3 | tr '\n' ' ')"
        fi
    done
}

# assert_present DIR VALUE...: each VALUE occurs in some file under DIR
assert_present() {
    local dir=$1 value
    shift
    for value in "$@"; do
        grep -rqaF -- "$value" "$dir" || fail "'$value' not found in $dir"
    done
}

# expect_fail_with MESSAGE COMMAND...: COMMAND fails and its stderr names MESSAGE
expect_fail_with() {
    local message=$1 err
    shift
    if err=$("$@" 2>&1 >/dev/null); then
        fail "expected failure ($message): $*"
    fi
    grep -qF -- "$message" <<<"$err" || fail "error lacks '$message': $err"
}

# unpack_image BIN DIR: the squashfs root of a NAND sysupgrade tar, unpacked into DIR/rootfs;
# /dev is left out because device nodes need root
unpack_image() {
    tar -xf "$1" -C "$2" --wildcards '*/root'
    unsquashfs -q -n -excludes -d "$2/rootfs" "$2"/sysupgrade-*/root dev >/dev/null
}

# fake_qmi_ib IB: the parts of an ImageBuilder that qmi-handler.sh touches (apk, .config, keys,
# repositories), with the stand-in apk of fixtures/fake-apk; FAKE_QMI_SH names the "package file"
fake_qmi_ib() {
    mkdir -p "$1/staging_dir/host/bin" "$1/keys"
    cp "$FIX/fake-apk" "$1/staging_dir/host/bin/apk"
    printf 'CONFIG_TARGET_ARCH_PACKAGES="fake_arch"\n' >"$1/.config"
    : >"$1/repositories"
}

# fake_make_image: the Makefile of a stand-in ImageBuilder whose `image` leaves what the real one
# does in build_dir: the package's file (0755) in root.orig-fake, the overlay's file (FILES=, copied
# with its mode) in root-fake. FAKE_QMI_ORIG, when set, is a package file other than the one apk gave.
# shellcheck disable=SC2016  # $(...) here are make's variables, written into the Makefile as they are
fake_make_image() {
    printf 'image:\n'
    printf '\tmkdir -p build_dir/target-fake/root.orig-fake/lib/netifd/proto'
    printf ' build_dir/target-fake/root-fake/lib/netifd/proto\n'
    printf '\tinstall -m 0755 $(or $(FAKE_QMI_ORIG),$(FAKE_QMI_SH))'
    printf ' build_dir/target-fake/root.orig-fake/lib/netifd/proto/qmi.sh\n'
    printf '\tcp -p $(FILES)/lib/netifd/proto/qmi.sh build_dir/target-fake/root-fake/lib/netifd/proto/qmi.sh\n'
}
