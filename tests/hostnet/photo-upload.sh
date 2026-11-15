#!/usr/bin/env bash
# R51: the request format of the QR photo, proved against a server on 127.0.0.1. The image's own
# nt_photo (src/files/usr/lib/lw/notify.sh) runs in the OpenWrt x86 rootfs under bwrap, WITHOUT a
# network namespace of its own, and sends sendPhoto with the rootfs's real uclient-fetch to a python3
# stdlib server (photo-server.py) that parses the multipart body and checks the headers (one
# Content-Type), the CRLF framing, the fields chat_id, parse_mode, caption and photo, and the photo
# bytes (all 256 byte values, CR LF, boundary look-alikes, 150 kB) for image/png and image/jpeg.
# Prints SKIP and exits 0 when it cannot run here: no python3, bwrap or rootfs, or no port to bind.
# Usage: tests/hostnet/photo-upload.sh   (LW_WORK as for the rootfs tests)
set -euo pipefail

FW="$(cd "$(dirname "$0")/../.." && pwd)"
LW_WORK=${LW_WORK:-$FW/work}
ROOTFS=${LW_ROOTFS:-$LW_WORK/dl/x86/rootfs}
here=$FW/tests/hostnet

skip() {
    echo "SKIP: $*"
    exit 0
}
command -v python3 >/dev/null || skip "no python3"
command -v bwrap >/dev/null || skip "no bwrap"
[ -x "$ROOTFS/bin/busybox" ] || skip "no rootfs at $ROOTFS (./fetch-deps.sh)"
bwrap --ro-bind / / --unshare-user true 2>/dev/null || skip "bwrap cannot make a namespace here"

tmp=$(mktemp -d)
server_pid=
cleanup() {
    [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
    rm -rf -- "$tmp"
}
trap cleanup EXIT

token='123456789:TESTtokq7x9-AAAAAAAAAAAAAAAAAAAAAAAAAAA'
mkdir -p "$tmp/expect"
printf '%s' "$token" >"$tmp/expect/token"

# the requests: a photo of each kind and a caption with what must survive the multipart body
python3 -I - "$tmp/expect" <<'PY'
import random, sys
from pathlib import Path
root = Path(sys.argv[1])
rnd = random.Random(87)
allbytes = bytes(range(256))
png = (b"\x89PNG\r\n\x1a\n" + allbytes + b"\r\n--lw-1004-1\r\n\r\n--" + b"\x00" * 7
       + bytes(rnd.randrange(256) for _ in range(150_000)) + b"\r\n")
jpeg = b"\xff\xd8\xff\xe0\x00\x10JFIF\x00" + allbytes[::-1] + b"\r\n--\r\n" + b"\xff\xd9"
caps = [
    "📶 <b>Wi-Fi</b>\nName: <code>Home-Guest</code>\nPassword: <code>blue-lamp-4521</code>\n\n"
    "Scan the code with the phone camera to join.",
    "📶 <b>Wi-Fi</b>\nName: <code>&lt;b&gt;&amp;\"a;b,c:d\\e%41 +x</code>\n"
    "Password: <code>Zażółć-hasło</code>\n\nScan the code with the phone camera to join.",
    "plain: \\n \\r\\n -- --boundary \"q\" 'q' ; = & % + é",
]
cases = [(png, "image/png", "wifi.png", caps[0], "-1001234567890"),
         (jpeg, "image/jpeg", "wifi.jpg", caps[1], "555000111"),
         (png[:100], "image/png", "wifi.png", caps[2], "-1001234567890")]
for i, (data, ctype, name, cap, chat) in enumerate(cases, 1):
    d = root / str(i)
    d.mkdir()
    (d / "photo").write_bytes(data)
    (d / "photo.type").write_text(ctype)
    (d / "photo.name").write_text(name)
    (d / "caption").write_bytes(cap.encode("utf-8"))
    (d / "chat_id").write_bytes(chat.encode())
PY
count=$(find "$tmp/expect" -mindepth 1 -maxdepth 1 -type d | wc -l)

python3 -I "$here/photo-server.py" "$tmp/port" "$tmp/expect" "$tmp/result" "$count" \
    >"$tmp/server.out" 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do
    [ -s "$tmp/port" ] && break
    kill -0 "$server_pid" 2>/dev/null || break
    sleep 0.1
done
if [ ! -s "$tmp/port" ]; then
    server_pid=
    skip "cannot start the local server: $(cat "$tmp/server.out")"
fi
port=$(cat "$tmp/port")

# like tests/rootfs/run.sh, but the network of the host stays (the one thing that run.sh unshares)
bwrap --overlay-src "$ROOTFS" --tmp-overlay / \
    --dev /dev --proc /proc --tmpfs /tmp \
    --ro-bind "$FW" /fw --ro-bind "$tmp/expect" /expect \
    --unshare-user --uid 0 --gid 0 --unshare-pid --die-with-parent \
    --clearenv --setenv PATH /fw/tests/stubs:/usr/sbin:/usr/bin:/sbin:/bin \
    --setenv HOME /root --setenv LW_TEST /lwtest --setenv PORT "$port" --setenv TOKEN "$token" \
    /bin/sh /fw/tests/hostnet/photo-client.inc >"$tmp/client.out" 2>&1 || {
    cat "$tmp/client.out" >&2
    echo "FAIL: the client failed" >&2
    exit 1
}
wait "$server_pid" || true
server_pid=

fail=0
check() {
    [ "$1" = "$2" ] || {
        echo "FAIL: $3: expected '$2', got '$1'" >&2
        fail=1
    }
}
check "$(grep -c '^rc=0 msgid=7$' "$tmp/client.out")" "$count" \
    "requests that nt_photo sent and Telegram accepted"
check "$(grep -c . "$tmp/client.out")" "$count" \
    "lines of the client output (nothing else: no files left in RAM, no error)"
check "$(grep -c "$token" "$tmp/client.out" || true)" 0 "the token in the client output"
check "$(cat "$tmp/result" 2>/dev/null || echo 'no result')" ok "the server's checks"
if [ "$fail" != 0 ]; then
    cat "$tmp/client.out" >&2
    exit 1
fi
echo "ok: $count uploads, one Content-Type each, binary-safe"
