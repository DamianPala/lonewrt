# Helpers for the host-side build tests (tests/build/[0-9][0-9]-*.sh), sourced by bash.
# Every test works on copies (LW_PROFILES, LW_SRC, LW_IMAGE) unless it builds the real generic image.
# shellcheck shell=bash disable=SC2034  # the variables are used by the tests that source this file
set -euo pipefail

FW="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT=$FW/tests/.out
FIX=$FW/tests/build/fixtures
RENDER=$OUT/render

LW_WORK=${LW_WORK:-$FW/work}
# R12g, D205: the build's test knobs for the pins work only under this suite
export LW_TESTS=1
# the made-up watchcat package files of fake-apk, and the sha256 pins the tests that build from them
# set (LW_WATCHCAT_SHA256, LW_WATCHCAT_INIT_SHA256, via fake_wc_pins)
export FAKE_WC_SH=$FIX/fake-watchcat.sh FAKE_WC_INIT=$FIX/fake-watchcat-init

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
# The fake Tailscale auth key (SPEC R66) is joined from two parts for the same reason
FAKE_TS_AUTHKEY="tskey-auth-""kTESTq7x9CNTRL-q7x9fakeauthkeyq7x9" # gitleaks:allow (synthetic)
# Made-up public keys (SPEC R61), generated with ssh-keygen for these tests and thrown away: A and E
# are the SSH_KEYS of fixtures/fake-full.conf, B, C and R only for the cases that build their own
# profile. Fields of a key: type, base64 data, comment.
FAKE_SSH_A='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDtjebEKCMyD5Axd0fck9Ocn1OgZmQhNul0Ncp1JYtt+ fake-a-q7x9'
FAKE_SSH_B='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFHF63RiGknO6QTxBQccyl9LCtKCX65r86YAAUJws0ic fake-b-q7x9'
FAKE_SSH_C='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMSo+/Ex00mQyD4rBqpFwf33Jju9gcPxYKXhOVVYrp/j fake-c-q7x9'
FAKE_SSH_E='ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBIb4S0E9CJVs37XjP+aVL29hb0goeiPSxe7xLh+tBNFNmyLGG9ek/3fmu4W7fevEjBjacTIogxLoWQ1JRoBTqHU= fake-e-q7x9'
FAKE_SSH_R='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQDbw/bZNzbHd+uT/PgpVJQ61Fxv/ufhl6Zs7F+Xemfb8pLl4Xauj5MEOCpT+belkAwjXoNKJvZ3QtsYrWKdJX1eP0HFeaumdW5dB9eoIudwW0iuVpFpqrVSMzjtGHzscX2yZ3YoZQx2eYN4oWA0srZCTEOTnafnPS8bHSzpV2JQkw== fake-r-q7x9'
# ssh_field KEY N: the Nth space-separated field of one of the lines above (1 type, 2 data, 3 comment)
ssh_field() { cut -d' ' -f"$2" <<<"$1"; }

# Values that only fixtures/fake-full.conf and fixtures/fake-full/ carry (SPEC R4, R4a)
FAKE_VALUES=(
    fakelw-q7x9 192.168.77.1 FakeLwSsid-q7x9 fake-wifi-key-q7x9 fakesaltq7x9 fake.apn.q7x9
    fakeuser-q7x9 fakepass-q7x9 73914826 "$FAKE_WG_PRIVATE_KEY"
    RkFLRS13Zy1wZWVyLXB1YmxpYy1rZXktcTd4OS0wMTI= 10.99.77. vpn.fake-q7x9.example
    FAKEauthorizedKEYq7x9 FAKE-dropbear-ed25519-host-key-q7x9 FAKE-dropbear-rsa-host-key-q7x9
    FAKEtgtokenq7x9 -1009977001977 hc-ping.fake-q7x9.example FAKEhcping-q7x9-0001
    +15550100123 15550100456 fake-a-q7x9 fake-e-q7x9 Acme-q7x9 "$FAKE_TS_AUTHKEY"
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
    sed -i -e "s|@FAKE_WG_PRIVATE_KEY@|$FAKE_WG_PRIVATE_KEY|" \
        -e "s|@FAKE_TS_AUTHKEY@|$FAKE_TS_AUTHKEY|" "$1/fake-full.conf"
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

# fake_wc_pins: export the sha256 pins of the made-up watchcat files (R14c); the build takes them
# only under the test suite (R12g)
fake_wc_pins() {
    LW_WATCHCAT_SHA256=$(sha256sum "$FAKE_WC_SH" | cut -d' ' -f1)
    LW_WATCHCAT_INIT_SHA256=$(sha256sum "$FAKE_WC_INIT" | cut -d' ' -f1)
    export LW_WATCHCAT_SHA256 LW_WATCHCAT_INIT_SHA256
}

# fake_make_image: the Makefile of a stand-in ImageBuilder whose `image` leaves what the real one
# does in build_dir: the package's file (0755) in root.orig-fake, the overlay's file (FILES=, copied
# with its mode) in root-fake. FAKE_QMI_ORIG, when set, is a package file other than the one apk gave;
# the same for watchcat's two files, whose package files are FAKE_WC_SH and FAKE_WC_INIT (FAKE_WC_ORIG
# and FAKE_WC_INIT_ORIG when another file is the pristine one).
# shellcheck disable=SC2016  # $(...) here are make's variables, written into the Makefile as they are
fake_make_image() {
    printf 'image:\n'
    printf '\tmkdir -p build_dir/target-fake/root.orig-fake/lib/netifd/proto'
    printf ' build_dir/target-fake/root-fake/lib/netifd/proto\n'
    printf '\tinstall -m 0755 $(or $(FAKE_QMI_ORIG),$(FAKE_QMI_SH))'
    printf ' build_dir/target-fake/root.orig-fake/lib/netifd/proto/qmi.sh\n'
    printf '\tcp -p $(FILES)/lib/netifd/proto/qmi.sh build_dir/target-fake/root-fake/lib/netifd/proto/qmi.sh\n'
    fake_make_watchcat
}

# fake_make_watchcat: the lines of an `image` recipe that do the same for watchcat's two files
# shellcheck disable=SC2016  # $(...) here are make's variables
fake_make_watchcat() {
    printf '\tmkdir -p build_dir/target-fake/root.orig-fake/usr/bin build_dir/target-fake/root.orig-fake/etc/init.d'
    printf ' build_dir/target-fake/root-fake/usr/bin build_dir/target-fake/root-fake/etc/init.d\n'
    printf '\tinstall -m 0755 $(or $(FAKE_WC_ORIG),$(FAKE_WC_SH)) build_dir/target-fake/root.orig-fake/usr/bin/watchcat.sh\n'
    printf '\tinstall -m 0755 $(or $(FAKE_WC_INIT_ORIG),$(FAKE_WC_INIT)) build_dir/target-fake/root.orig-fake/etc/init.d/watchcat\n'
    printf '\tcp -p $(FILES)/usr/bin/watchcat.sh build_dir/target-fake/root-fake/usr/bin/watchcat.sh\n'
    printf '\tcp -p $(FILES)/etc/init.d/watchcat build_dir/target-fake/root-fake/etc/init.d/watchcat\n'
}
