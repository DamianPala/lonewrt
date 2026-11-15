"""A fake Telegram Bot API for sendPhoto on 127.0.0.1, for tests/hostnet/photo-upload.sh.

It checks the upload the way a strict server would, from the bytes it receives:
- POST to /bot<token>/sendPhoto, exactly one Content-Type header, multipart/form-data with a boundary
  of the characters RFC 2046 allows, a body in chunked transfer encoding or with a Content-Length;
- the body: every part starts with the delimiter and CRLF, headers end with CRLF CRLF, every part
  ends with CRLF before the next delimiter, the closing delimiter is followed by CRLF and nothing
  more, the boundary is in no part's data;
- the fields are exactly chat_id, parse_mode, caption and photo, in the values of the expect folder;
  the photo part has the file name and content type of the expect folder and the same bytes.

Usage: photo-server.py PORT_FILE EXPECT_DIR RESULT_FILE COUNT
  binds 127.0.0.1 on a free port (written to PORT_FILE once it listens; exit 3 when it cannot bind),
  serves COUNT requests, writes "ok" or the list of failures to RESULT_FILE.
  EXPECT_DIR/N/ holds, for the Nth request: chat_id, caption (UTF-8 bytes, exactly), photo (bytes),
  photo.type, photo.name; EXPECT_DIR/token holds the token of the URL.
"""

import http.server
import re
import socketserver
import sys
from pathlib import Path

BOUNDARY_RE = re.compile(r"^[0-9A-Za-z'()+_,\-./:=?]{1,70}$")


def read_chunked(rfile):
    body = b""
    while True:
        line = rfile.readline()
        size = int(line.split(b";")[0].strip() or b"0", 16)
        if size == 0:
            # trailer headers (none expected) end with an empty line
            while rfile.readline() not in (b"\r\n", b"\n", b""):
                pass
            return body
        body += rfile.read(size)
        if rfile.read(2) != b"\r\n":
            raise ValueError("chunk without CRLF")


def parse_multipart(body, boundary, fail):
    """The parts of a multipart body as a list of (headers dict, data bytes)."""
    delim = b"--" + boundary
    if not body.startswith(delim + b"\r\n"):
        fail("body does not start with the delimiter and CRLF")
        return []
    if not body.endswith(b"\r\n" + delim + b"--\r\n"):
        fail("body does not end with CRLF, the closing delimiter and CRLF")
        return []
    inner = body[len(delim) + 2 : -(len(delim) + 6)]
    pieces = inner.split(b"\r\n" + delim + b"\r\n")
    parts = []
    for piece in pieces:
        head, sep, data = piece.partition(b"\r\n\r\n")
        if not sep:
            fail("a part has no empty line after its headers")
            continue
        headers = {}
        for line in head.split(b"\r\n"):
            if b":" not in line:
                fail("a part header line has no colon: %r" % line[:40])
                continue
            k, v = line.split(b":", 1)
            headers[k.decode("ascii").strip().lower()] = v.decode("utf-8").strip()
        parts.append((headers, data))
    return parts


def check_request(n, method, path, headers, body, expect, token, fail):
    if method != "POST":
        fail("request %d: method %s" % (n, method))
    if path != "/bot%s/sendPhoto" % token:
        fail("request %d: path is not /bot<token>/sendPhoto" % n)
    cts = [v for k, v in headers if k.lower() == "content-type"]
    if len(cts) != 1:
        fail("request %d: %d Content-Type headers: %r" % (n, len(cts), cts))
        return
    m = re.fullmatch(r"multipart/form-data; boundary=(.+)", cts[0])
    if not m or not BOUNDARY_RE.match(m.group(1)):
        fail("request %d: Content-Type %r" % (n, cts[0]))
        return
    boundary = m.group(1).encode()
    lens = [v for k, v in headers if k.lower() == "content-length"]
    if lens and int(lens[0]) != len(body):
        fail("request %d: Content-Length %s but body %d" % (n, lens[0], len(body)))
    parts = parse_multipart(body, boundary, lambda msg: fail("request %d: %s" % (n, msg)))
    names = []
    fields = {}
    for hd, data in parts:
        cd = hd.get("content-disposition", "")
        nm = re.search(r'\bname="([^"]*)"', cd)
        if not cd.startswith("form-data") or not nm:
            fail("request %d: bad Content-Disposition %r" % (n, cd))
            continue
        names.append(nm.group(1))
        fields[nm.group(1)] = (hd, data, cd)
        if b"--" + boundary in data:
            fail("request %d: the boundary is inside the data of %s" % (n, nm.group(1)))
    if sorted(names) != ["caption", "chat_id", "parse_mode", "photo"]:
        fail("request %d: fields %r" % (n, names))
        return
    exp = Path(expect) / str(n)
    if fields["chat_id"][1] != (exp / "chat_id").read_bytes():
        fail("request %d: chat_id %r" % (n, fields["chat_id"][1]))
    if fields["parse_mode"][1] != b"HTML":
        fail("request %d: parse_mode %r" % (n, fields["parse_mode"][1]))
    if fields["caption"][1] != (exp / "caption").read_bytes():
        fail("request %d: caption differs: %r" % (n, fields["caption"][1][:80]))
    if len(fields["caption"][1].decode("utf-8")) > 1024:
        fail("request %d: caption over 1024 characters" % n)
    hd, data, cd = fields["photo"]
    fname = (exp / "photo.name").read_text()
    if not re.search(r'filename="%s"' % re.escape(fname), cd):
        fail("request %d: photo Content-Disposition %r" % (n, cd))
    if hd.get("content-type") != (exp / "photo.type").read_text():
        fail("request %d: photo Content-Type %r" % (n, hd.get("content-type")))
    if data != (exp / "photo").read_bytes():
        fail(
            "request %d: the photo bytes differ (%d received, %d expected)"
            % (n, len(data), len((exp / "photo").read_bytes()))
        )


class Server(socketserver.TCPServer):
    allow_reuse_address = True


def main():
    port_file, expect, result_file, count = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
    token = (Path(expect) / "token").read_text().strip()
    failures = []
    seen = [0]

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_POST(self):
            seen[0] += 1
            n = seen[0]
            headers = list(self.headers.items())
            if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
                body = read_chunked(self.rfile)
            else:
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            before = len(failures)
            check_request(n, self.command, self.path, headers, body, expect, token, failures.append)
            ok = len(failures) == before
            reply = b'{"ok":true,"result":{"message_id":7}}' if ok else b'{"ok":false}'
            self.send_response(200 if ok else 400)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(reply)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(reply)
            self.close_connection = True

        def log_message(self, format, *args):  # noqa: A002  (the name is the base class's)
            """No access log: a request line holds the token."""

    try:
        server = Server(("127.0.0.1", 0), Handler)
    except OSError as exc:
        print("cannot bind 127.0.0.1: %s" % exc, file=sys.stderr)
        sys.exit(3)
    Path(port_file).write_text(str(server.server_address[1]))
    server.timeout = 30
    for _ in range(count):
        server.handle_request()
    if seen[0] != count:
        failures.append("%d requests instead of %d" % (seen[0], count))
    Path(result_file).write_text("ok\n" if not failures else "\n".join(failures) + "\n")


main()
