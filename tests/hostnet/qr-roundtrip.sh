#!/usr/bin/env bash
# R51: the QR picture of /wifi, from the text of the code to a JPEG, read back with a real decoder.
# In the OpenWrt rootfs under bwrap the image's own code runs: nt_qr_wifi makes the string for names
# and passwords with every special character, nt_qr_pgm (busybox awk) turns the text drawing of the
# host's `qrencode -t ASCII -m 4` into a PGM picture, and nt_qr_image runs the whole pipeline with
# the real `cjpeg` of libjpeg-turbo-utils (quality 90) when that is there. The host's zbarimg reads
# every PGM and JPEG back, and a reader of the WIFI: format (the rules phone cameras follow: fields
# X:value; with \ before \ ; , : ") must find the name, the password, the type and the hidden flag
# that went in.
# cjpeg: x86_64 build of the package in $LW_WORK/dl/x86/jpeg (./fetch-deps.sh jpeg), or the folder
# LW_CJPEG_ROOT (with usr/bin/cjpeg and usr/lib/libjpeg.so*). Without it the JPEG step is left out
# and the test says so; without the host's qrencode, zbarimg, python3 or bwrap it prints SKIP.
# Usage: tests/hostnet/qr-roundtrip.sh   (LW_WORK as for the rootfs tests)
set -euo pipefail

FW="$(cd "$(dirname "$0")/../.." && pwd)"
LW_WORK=${LW_WORK:-$FW/work}
ROOTFS=${LW_ROOTFS:-$LW_WORK/dl/x86/rootfs}
CJPEG_ROOT=${LW_CJPEG_ROOT:-$LW_WORK/dl/x86/jpeg}

skip() {
    echo "SKIP: $*"
    exit 0
}
for c in qrencode zbarimg python3 bwrap; do
    command -v "$c" >/dev/null || skip "no $c on the host"
done
[ -x "$ROOTFS/bin/busybox" ] || skip "no rootfs at $ROOTFS (./fetch-deps.sh)"
bwrap --ro-bind / / --unshare-user true 2>/dev/null || skip "bwrap cannot make a namespace here"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/ascii" "$tmp/text" "$tmp/out" "$tmp/stubbin"
have_cjpeg=0
[ -x "$CJPEG_ROOT/usr/bin/cjpeg" ] && have_cjpeg=1

# SSID, key, hidden: fields separated by the control character 0x1F, which no name can hold
us=$'\x1f'
cases=(
    "HomeWifi${us}secret-pass-1${us}"
    "Home-Guest${us}blue-lamp-4521${us}1"
    "Guest${us}${us}"
    "Guest${us}${us}1"
    "a\\b${us}c\\d${us}"
    "a;b${us}c;d${us}"
    "a,b${us}c,d${us}"
    "a:b${us}c:d${us}"
    "a\"b${us}c\"d${us}"
    "\\;,:\"${us}\"\\:,;${us}"
    ";start${us}end\\${us}"
    "\\\\${us}x${us}"
    " Karo's WiFi ${us}p&ss=w0rd%41 +x<i>${us}"
    "Zażółć${us}hasło-żółw-77${us}"
    "12345678${us}87654321${us}"
    "S:x${us}P:y${us}"
    "WIFI:T:WPA;S:a;P:b;;${us}k${us}"
    "abcdefghijklmnopqrstuvwxyz012345${us}$(printf 'q;%.0s' $(seq 1 31))q${us}1"
    "$(printf ';%.0s' $(seq 1 32))${us}$(printf ';%.0s' $(seq 1 63))${us}"
)
printf '%s\n' "${cases[@]}" >"$tmp/cases"

# the strings of the image's nt_qr_wifi
sandbox() {
    bwrap --overlay-src "$ROOTFS" --tmp-overlay / --dev /dev --proc /proc --tmpfs /tmp \
        --ro-bind "$FW" /fw --unshare-user --uid 0 --gid 0 --unshare-net --unshare-pid \
        --die-with-parent --clearenv --setenv PATH /usr/sbin:/usr/bin:/sbin:/bin \
        --setenv HOME /root --setenv NT_RUN /tmp/nt --setenv LW_TEST /lwtest "$@"
}
# shellcheck disable=SC2016  # the script in single quotes is for the sandbox's shell
sandbox --ro-bind "$tmp/cases" /cases /bin/sh -c '
    . /fw/src/files/usr/lib/lw/common.sh
    . /fw/src/files/usr/lib/lw/notify.sh
    . /fw/src/files/usr/lib/lw/devices.sh
    us=$(printf "\037")
    while IFS=$us read -r s k h; do
        printf "%s\037%s\037%s\037%s\n" "$s" "$k" "$h" "$(nt_qr_wifi "$s" "$k" "$h")"
    done </cases' >"$tmp/strings"

# the text of each code, and what the host's qrencode draws of it
python3 -I - "$tmp" <<'PY'
import subprocess, sys
from pathlib import Path

tmp = Path(sys.argv[1])
rows = tmp.joinpath("strings").read_text(encoding="utf-8").rstrip("\n").split("\n")
for n, row in enumerate(rows, 1):
    qr = row.split("\x1f")[3]
    (tmp / "text" / str(n)).write_text(qr, encoding="utf-8")
    ascii_art = subprocess.run(["qrencode", "-t", "ASCII", "-m", "4"], input=qr.encode("utf-8"),
                               check=True, capture_output=True).stdout
    (tmp / "ascii" / str(n)).write_bytes(ascii_art)
PY

# the stand-ins of the sandbox: qrencode gives the drawing the host made, cjpeg is the real one
printf '#!/bin/sh\ncat >/dev/null\ncat "$QR_ASCII"\n' >"$tmp/stubbin/qrencode"
printf '#!/bin/sh\nLD_LIBRARY_PATH=/cj/usr/lib exec /cj/usr/bin/cjpeg "$@"\n' >"$tmp/stubbin/cjpeg"
chmod +x "$tmp/stubbin/qrencode" "$tmp/stubbin/cjpeg"
cj=()
[ "$have_cjpeg" = 0 ] || cj=(--ro-bind "$CJPEG_ROOT" /cj)
# shellcheck disable=SC2016
sandbox "${cj[@]}" --ro-bind "$tmp/ascii" /ascii --ro-bind "$tmp/text" /text \
    --bind "$tmp/out" /out --ro-bind "$tmp/stubbin" /stubbin /bin/sh -c '
    . /fw/src/files/usr/lib/lw/common.sh
    . /fw/src/files/usr/lib/lw/notify.sh
    . /fw/src/files/usr/lib/lw/devices.sh
    mkdir -p "$NT_RUN"
    PATH=/stubbin:$PATH
    n=1
    while [ -f "/ascii/$n" ]; do
        nt_qr_pgm </ascii/$n >"/out/$n.pgm" || echo "nt_qr_pgm failed for $n"
        if [ -x /cj/usr/bin/cjpeg ]; then
            QR_ASCII=/ascii/$n nt_qr_image "$(cat "/text/$n")" || echo "nt_qr_image failed for $n"
            [ "$NT_IMG_TYPE" = image/jpeg ] || echo "type $NT_IMG_TYPE for $n"
            cp "$NT_IMG" "/out/$n.jpg" && rm -f "$NT_IMG"
        fi
        n=$((n + 1))
    done' >"$tmp/sandbox.out" 2>&1
[ ! -s "$tmp/sandbox.out" ] || { cat "$tmp/sandbox.out" >&2; exit 1; }

python3 -I - "$tmp" "$have_cjpeg" <<'PY'
import subprocess, sys
from pathlib import Path

tmp = Path(sys.argv[1])
have_cjpeg = sys.argv[2] == "1"


def read_wifi(text):
    """The reader of the WIFI: format: returns {field: value}, unescaping \\x."""
    assert text.startswith("WIFI:"), text
    fields, i, n = {}, 5, len(text)
    while i < n and text[i] != ";":
        j = text.index(":", i)
        key = text[i:j]
        val, i = "", j + 1
        while i < n and text[i] != ";":
            if text[i] == "\\":
                i += 1
            val += text[i]
            i += 1
        i += 1
        if key:
            fields[key] = val
    return fields


def jpeg_width(data):
    """The width in the start-of-frame marker of a JPEG."""
    i = 2
    while i + 9 < len(data):
        marker, length = data[i + 1], int.from_bytes(data[i + 2 : i + 4], "big")
        if data[i] == 0xFF and 0xC0 <= marker <= 0xC3:
            return int.from_bytes(data[i + 7 : i + 9], "big")
        i += 2 + length
    return 0


def decode(path):
    out = subprocess.run(["zbarimg", "--raw", "-q", str(path)], capture_output=True)
    return out.stdout.decode("utf-8").rstrip("\n")


bad = 0
checked = 0
rows = tmp.joinpath("strings").read_text(encoding="utf-8").rstrip("\n").split("\n")
for n, row in enumerate(rows, 1):
    ssid, key, hidden, qr = row.split("\x1f")
    want = {"T": "WPA" if key else "nopass", "S": ssid}
    if key:
        want["P"] = key
    if hidden == "1":
        want["H"] = "true"
    images = [tmp / "out" / ("%d.pgm" % n)]
    if have_cjpeg:
        images.append(tmp / "out" / ("%d.jpg" % n))
    for img in images:
        checked += 1
        decoded = decode(img)
        try:
            got = read_wifi(decoded)
        except (AssertionError, ValueError, IndexError):
            got = {"unreadable": decoded}
        if decoded != qr or got != want:
            bad += 1
            print("FAIL case %d (%s): string %r, decoded %r, read %r, wanted %r"
                  % (n, img.suffix, qr, decoded, got, want), file=sys.stderr)
        if img.suffix == ".jpg" and not img.read_bytes().startswith(b"\xff\xd8\xff"):
            bad += 1
            print("FAIL case %d: not a JPEG" % n, file=sys.stderr)
        if img.suffix == ".jpg":
            width = jpeg_width(img.read_bytes())
            if not 390 <= width <= 600:
                bad += 1
                print("FAIL case %d: the JPEG is %d pixels wide" % (n, width), file=sys.stderr)
note = "" if have_cjpeg else " (the JPEG step is left out: no cjpeg, see ./fetch-deps.sh jpeg)"
if bad:
    print("%d of %d pictures failed" % (bad, checked))
    sys.exit(1)
print("ok: %d pictures of %d codes read back%s" % (checked, len(rows), note))
PY
