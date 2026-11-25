#!/usr/bin/env python3
"""A capture of the router's LAN link for the LAN IPv6 loss scenario (tests/vm/96-lan6.sh): it is the
other end of the router's LAN NIC (run with python3 -I, standard library only).

QEMU's `-netdev stream` (vm.py start --link-role server --link-sock SOCK) listens on the socket this
program connects to; every frame is a 4-byte big-endian length and the Ethernet frame. The program
only listens and, when the file `rs` appears in the --ctl directory, sends one router solicitation
(and removes the file, and adds a line to `rs.sent`, so a scenario can tell a quiet link from a
peer that sent nothing). Every router advertisement it sees is one line of the --log file:

  T RA lifetime=<router lifetime> flags=<hex> [pio=<prefix>/<len> pref=<s> valid=<s> flags=<hex>]...
  [rdnss=<lifetime> <address>] [mtu=<n>]

T is the second since the program started (one decimal), so the scenario can tell the last
advertisement of a withdrawal from the ones before it. The scenario reads the lines with `awk` and
counts the advertisements after a mark it takes from `lines`.
"""

import argparse
import ipaddress
import os
import select
import socket
import struct
import sys
import time

MAC = bytes.fromhex("525400000099")
LL = ipaddress.IPv6Address("fe80::5054:ff:fe00:99").packed
ALL_ROUTERS = ipaddress.IPv6Address("ff02::2").packed
ALL_ROUTERS_MAC = bytes.fromhex("333300000002")


def checksum(data):
    if len(data) % 2:
        data += b"\0"
    total = sum(struct.unpack(f"!{len(data) // 2}H", data))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return (~total) & 0xFFFF


def solicitation():
    body = struct.pack("!BBHI", 133, 0, 0, 0) + b"\x01\x01" + MAC
    pseudo = LL + ALL_ROUTERS + struct.pack("!I", len(body)) + b"\0\0\0" + bytes([58])
    body = body[:2] + struct.pack("!H", checksum(pseudo + body)) + body[4:]
    ip = struct.pack("!IHBB", 0x60000000, len(body), 58, 255) + LL + ALL_ROUTERS
    return ALL_ROUTERS_MAC + MAC + b"\x86\xdd" + ip + body


def describe(body):
    """The words of one router advertisement (the ICMPv6 body), or None for anything else."""
    if len(body) < 16 or body[0] != 134:
        return None
    _, _, _, _, flags, lifetime = struct.unpack("!BBHBBH", body[:8])
    words = [f"lifetime={lifetime}", f"flags={flags:02x}"]
    i = 16
    while i + 2 <= len(body):
        typ, length = body[i], body[i + 1] * 8
        if length == 0 or i + length > len(body):
            break
        opt = body[i : i + length]
        if typ == 3 and length == 32:
            plen, pflags, valid, pref = struct.unpack("!BBII", opt[2:12])
            addr = ipaddress.IPv6Address(opt[16:32])
            words.append(
                f"pio={addr}/{plen} pref={pref} valid={valid} flags={pflags:02x}"
            )
        elif typ == 25 and length >= 24:
            words.append(
                f"rdnss={struct.unpack('!I', opt[4:8])[0]} {ipaddress.IPv6Address(opt[8:24])}"
            )
        elif typ == 5:
            words.append(f"mtu={struct.unpack('!I', opt[4:8])[0]}")
        i += length
    return " ".join(words)


def read_frame(conn, buf):
    while len(buf) < 4 or len(buf) < 4 + struct.unpack("!I", buf[:4])[0]:
        data = conn.recv(65536)
        if not data:
            return None, buf
        buf += data
    n = struct.unpack("!I", buf[:4])[0]
    return buf[4 : 4 + n], buf[4 + n :]


def connect(path):
    end = time.monotonic() + 60
    while time.monotonic() < end:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            conn.connect(path)
            return conn
        except OSError:
            conn.close()
            time.sleep(0.2)
    sys.exit(f"lan-ra-peer: nothing listens on {path}")


def main():
    ap = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    ap.add_argument(
        "--sock",
        required=True,
        help="unix socket of the router's LAN NIC (QEMU listens)",
    )
    ap.add_argument(
        "--ctl",
        required=True,
        help="directory where a file `rs` asks for a solicitation",
    )
    ap.add_argument(
        "--log", required=True, help="file that gets one line per advertisement"
    )
    args = ap.parse_args()
    t0 = time.monotonic()
    log = open(args.log, "a", encoding="ascii", buffering=1)
    conn = connect(args.sock)
    buf = b""
    rs = os.path.join(args.ctl, "rs")
    print("ready", flush=True)
    while True:
        if os.path.exists(rs):
            os.unlink(rs)
            out = solicitation()
            conn.sendall(struct.pack("!I", len(out)) + out)
            with open(os.path.join(args.ctl, "rs.sent"), "a", encoding="ascii") as sent:
                sent.write("rs\n")
        if not select.select([conn], [], [], 0.2)[0]:
            continue
        try:
            frame, buf = read_frame(conn, buf)
        except OSError:
            break
        if frame is None:
            break
        if len(frame) < 62 or frame[12:14] != b"\x86\xdd" or frame[20] != 58:
            continue
        words = describe(frame[54:])
        if words:
            log.write(f"{time.monotonic() - t0:7.1f} RA {words}\n")


if __name__ == "__main__":
    main()
