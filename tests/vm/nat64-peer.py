#!/usr/bin/env python3
"""The WAN peer of the IPv6-only scenario (tests/vm/95-clat.sh): what the operator is, to the
router's wwan NIC (run with python3 -I, standard library only).

QEMU's `-netdev stream` (vm.py start --wwan-peer SOCK) connects the NIC to the unix socket this
program listens on; every frame is a 4-byte big-endian length and the Ethernet frame. The peer is
all of this, as little as the scenario needs:

  * the router of a mobile IPv6 link: router advertisements (to the all-nodes address every few
    seconds and to every router solicitation) with a /64 prefix to build an address from (not
    on-link, as on a mobile network) and an RDNSS option, so odhcp6c of the router's IPv6 child
    gets its address, default route and DNS server from the link, as on a real session; it answers
    neighbour solicitations for its link-local address, its global address and its DNS address,
    and ICMPv6 echo requests to any address that is not behind the NAT64;
  * a DNS64: on its DNS address, UDP port 53, AAAA for ipv4only.arpa (192.0.0.170 and 192.0.0.171)
    and for the names of NAMES, each with the NAT64 prefix in front of the IPv4 address; A for the
    names of NAMES as they are; nothing else (an answer with no address);
  * a NAT64: an ICMPv6 echo request to PREFIX::a.b.c.d is answered as the IPv4 host a.b.c.d would
    answer the translated request, and a TCP connection to PREFIX::a.b.c.d (any port) is accepted;
    the first segment with data gets the one line `lwvm-nat64 a.b.c.d` and a FIN (it is what a CLAT
    behind a working NAT64 sees). A TCP connection to any other address is accepted the same way,
    with the line `lwvm-native ADDRESS`.

The scenario switches the behind-the-NAT64 parts with files in the --ctl directory: `dns64`, `nat64`
and `ra`, containing `off` (anything else, or no file, is on); `dns64` can also hold `drop`: the
questions for ipv4only.arpa and the names get no answer at all. A file `prefix` with a /96 replaces
the NAT64 prefix from then on (a new session with another operator prefix). Every packet it acted on is one line
of the --log file, for the scenario to read: `ns TARGET`, `rs`, `ra`, `echo6 DST SRC`, `echo4
A.B.C.D SRC`, `tcp4 A.B.C.D PORT SRC`, `tcp6 ADDRESS PORT SRC`, `dns TYPE NAME answered|empty|off|dropped`,
`nat64-off A.B.C.D`.
"""

import argparse
import ipaddress
import os
import select
import socket
import struct
import sys
import time

NAMES = {"ipv4-only.example.net": "8.8.4.4"}  # dnsmasq drops a TEST-NET answer as a rebind attack
V4ONLY = ("192.0.0.170", "192.0.0.171")
ALL_NODES = ipaddress.IPv6Address("ff02::1").packed
ALL_NODES_MAC = bytes.fromhex("333300000001")
RA_EVERY = 5.0
TCP_FIN, TCP_SYN, TCP_RST, TCP_PSH, TCP_ACK = 0x01, 0x02, 0x04, 0x08, 0x10


def checksum(data):
    if len(data) % 2:
        data += b"\0"
    total = sum(struct.unpack(f"!{len(data) // 2}H", data))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return (~total) & 0xFFFF


def l4_checksum(src, dst, proto, body):
    pseudo = src + dst + struct.pack("!I", len(body)) + b"\0\0\0" + bytes([proto])
    return checksum(pseudo + body) or 0xFFFF


def ipv6_frame(eth_dst, eth_src, src, dst, proto, body, hlim=64):
    ip = struct.pack("!IHBB", 0x60000000, len(body), proto, hlim) + src + dst
    return eth_dst + eth_src + b"\x86\xdd" + ip + body


def icmp6(typ, rest):
    return struct.pack("!BBH", typ, 0, 0) + rest


def with_checksum(src, dst, proto, body, at):
    s = l4_checksum(src, dst, proto, body)
    return body[:at] + struct.pack("!H", s) + body[at + 2 :]


class Peer:
    def __init__(self, args):
        self.mac = bytes.fromhex(args.mac.replace(":", ""))
        self.gw = ipaddress.IPv6Address(args.gateway).packed
        self.ll = ipaddress.IPv6Address(args.link_local).packed
        self.dns = ipaddress.IPv6Address(args.dns).packed
        self.ra_prefix = ipaddress.IPv6Network(args.ra_prefix)
        if self.ra_prefix.prefixlen != 64:
            sys.exit("nat64-peer: the router advertisement prefix must be a /64")
        self.pfx0 = self.parse_prefix(args.prefix)
        self.ctl = args.ctl
        self.log = open(args.log, "a", encoding="ascii", buffering=1)
        self.tcp = {}
        self.next_ra = 0.0

    @staticmethod
    def parse_prefix(text):
        net = ipaddress.IPv6Network(text.strip())
        if net.prefixlen != 96:
            sys.exit("nat64-peer: the NAT64 prefix must be a /96")
        return int(net.network_address) >> 32

    @property
    def pfx(self):
        try:
            with open(os.path.join(self.ctl, "prefix"), encoding="ascii") as f:
                return self.parse_prefix(f.read())
        except (OSError, ValueError):
            return self.pfx0

    def on(self, name):
        try:
            with open(os.path.join(self.ctl, name), encoding="ascii") as f:
                return f.read().strip() != "off"
        except OSError:
            return True

    def mode(self, name):
        try:
            with open(os.path.join(self.ctl, name), encoding="ascii") as f:
                return f.read().strip() or "on"
        except OSError:
            return "on"

    def note(self, text):
        self.log.write(text + "\n")

    def embed(self, v4):
        return ipaddress.IPv6Address((self.pfx << 32) | int(ipaddress.IPv4Address(v4))).packed

    def behind_nat64(self, dst):
        return int.from_bytes(dst, "big") >> 32 == self.pfx

    def v4_of(self, dst):
        return str(ipaddress.IPv4Address(int.from_bytes(dst[12:], "big")))

    def ra(self, dst_mac, dst):
        """One router advertisement: source link-layer address, a /64 prefix to build an address
        from (autonomous, not on-link), RDNSS with the DNS address."""
        if not self.on("ra"):
            return []
        pio = struct.pack("!BBBBIII", 3, 4, 64, 0x40, 86400, 14400, 0) + self.ra_prefix.network_address.packed
        rdnss = struct.pack("!BBHI", 25, 3, 0, 3600) + self.dns
        body = icmp6(134, struct.pack("!BBHII", 64, 0, 1800, 0, 0) + b"\x01\x01" + self.mac + pio + rdnss)
        body = with_checksum(self.ll, dst, 58, body, 2)
        self.note("ra")
        return [ipv6_frame(dst_mac, self.mac, self.ll, dst, 58, body, 255)]

    def tick(self):
        """The unsolicited advertisements, every RA_EVERY seconds."""
        now = time.monotonic()
        if now < self.next_ra:
            return []
        self.next_ra = now + RA_EVERY
        return self.ra(ALL_NODES_MAC, ALL_NODES)

    def handle(self, frame):
        if len(frame) < 54 or frame[12:14] != b"\x86\xdd":
            return []
        src_mac = frame[6:12]
        proto = frame[20]
        src, dst = frame[22:38], frame[38:54]
        body = frame[54 : 54 + struct.unpack("!H", frame[18:20])[0]]
        if proto == 58 and body:
            return self.icmp(src_mac, src, dst, body)
        if proto == 17 and len(body) >= 8 and dst == self.dns:
            return self.udp(src_mac, src, dst, body)
        if proto == 6 and len(body) >= 20 and dst[0] != 0xFF:
            return self.tcp_segment(src_mac, src, dst, body)
        return []

    def icmp(self, src_mac, src, dst, body):
        typ = body[0]
        if typ == 133:  # router solicitation
            self.note("rs")
            return self.ra(src_mac, src)
        if typ == 135 and len(body) >= 24:  # neighbour solicitation
            target = body[8:24]
            if target not in (self.gw, self.ll, self.dns) or src == bytes(16):
                return []
            self.note(f"ns {ipaddress.IPv6Address(target)}")
            na = icmp6(136, struct.pack("!I", 0xE0000000) + target + b"\x02\x01" + self.mac)
            na = with_checksum(target, src, 58, na, 2)
            return [ipv6_frame(src_mac, self.mac, target, src, 58, na, 255)]
        if typ == 128 and len(body) >= 8:  # echo request
            if dst[0] == 0xFF:
                return []
            if self.behind_nat64(dst):
                v4 = self.v4_of(dst)
                if not self.on("nat64"):
                    self.note(f"nat64-off {v4}")
                    return []
                self.note(f"echo4 {v4} {ipaddress.IPv6Address(src)}")
            else:
                self.note(f"echo6 {ipaddress.IPv6Address(dst)} {ipaddress.IPv6Address(src)}")
            rep = with_checksum(dst, src, 58, icmp6(129, body[4:]), 2)
            return [ipv6_frame(src_mac, self.mac, dst, src, 58, rep)]
        return []

    def tcp_reply(self, src_mac, peer_src, peer_dst, sport, dport, seq, ack, flags, payload=b"", opts=b""):
        """A segment from the server (peer_dst, dport) to the client (peer_src, sport)."""
        hdr = struct.pack("!HHIIBBHHH", dport, sport, seq, ack, (5 + len(opts) // 4) << 4, flags, 65535, 0, 0)
        seg = with_checksum(peer_dst, peer_src, 6, hdr + opts + payload, 16)
        return ipv6_frame(src_mac, self.mac, peer_dst, peer_src, 6, seg)

    def tcp_segment(self, src_mac, src, dst, body):
        sport, dport, seq, ack, off, flags = struct.unpack("!HHIIBB", body[:14])
        payload = body[(off >> 4) * 4 :]
        key = (src, sport, dst, dport)
        nat = self.behind_nat64(dst)
        if flags & TCP_RST:
            self.tcp.pop(key, None)
            return []
        if flags & TCP_SYN and not flags & TCP_ACK:
            if nat and not self.on("nat64"):
                self.note(f"nat64-off {self.v4_of(dst)}")
                return []
            if nat:
                self.note(f"tcp4 {self.v4_of(dst)} {dport} {ipaddress.IPv6Address(src)}")
            else:
                self.note(f"tcp6 {ipaddress.IPv6Address(dst)} {dport} {ipaddress.IPv6Address(src)}")
            isn = 0x1000 + (len(self.tcp) * 0x10000)
            self.tcp[key] = {"seq": isn + 1, "fin": False}
            return [self.tcp_reply(src_mac, src, dst, sport, dport, isn, (seq + 1) & 0xFFFFFFFF,
                                   TCP_SYN | TCP_ACK, opts=b"\x02\x04\x05\x00")]
        st = self.tcp.get(key)
        if st is None:
            return []
        nxt = (seq + len(payload) + (1 if flags & TCP_FIN else 0)) & 0xFFFFFFFF
        out = []
        if payload and not st["fin"]:
            line = (f"lwvm-nat64 {self.v4_of(dst)}\n" if nat else f"lwvm-native {ipaddress.IPv6Address(dst)}\n").encode()
            out.append(self.tcp_reply(src_mac, src, dst, sport, dport, st["seq"], nxt,
                                      TCP_PSH | TCP_ACK | TCP_FIN, payload=line))
            st["seq"] += len(line) + 1
            st["fin"] = True
        elif payload or flags & TCP_FIN:
            out.append(self.tcp_reply(src_mac, src, dst, sport, dport, st["seq"], nxt, TCP_ACK))
        if flags & TCP_FIN and st["fin"]:
            self.tcp.pop(key, None)
        return out

    def udp(self, src_mac, src, dst, body):
        sport, dport, length = struct.unpack("!HHH", body[:6])
        if dport != 53:
            return []
        reply = self.dns_answer(body[8:length])
        if reply is None:
            return []
        udp = struct.pack("!HHHH", 53, sport, 8 + len(reply), 0) + reply
        udp = with_checksum(dst, src, 17, udp, 6)
        return [ipv6_frame(src_mac, self.mac, dst, src, 17, udp)]

    def dns_answer(self, q):
        if len(q) < 17:
            return None
        ident = q[:2]
        i = 12
        labels = []
        while i < len(q) and q[i]:
            labels.append(q[i + 1 : i + 1 + q[i]].decode("ascii", "replace").lower())
            i += 1 + q[i]
        qend = i + 5
        if qend > len(q):
            return None
        name = ".".join(labels)
        qtype = struct.unpack("!H", q[i + 1 : i + 3])[0]
        answers = []
        if qtype == 28 and self.mode("dns64") == "drop" and (name == "ipv4only.arpa" or name in NAMES):
            self.note(f"dns AAAA {name} dropped")
            return None
        if qtype == 28 and self.on("dns64"):
            if name == "ipv4only.arpa":
                answers = [self.embed(v) for v in V4ONLY]
            elif name in NAMES:
                answers = [self.embed(NAMES[name])]
        elif qtype == 1 and name in NAMES:
            answers = [ipaddress.IPv4Address(NAMES[name]).packed]
        kind = "answered" if answers else ("off" if qtype == 28 and not self.on("dns64") else "empty")
        self.note(f"dns {'AAAA' if qtype == 28 else qtype} {name} {kind}")
        out = ident + struct.pack("!HHHHH", 0x8180, 1, len(answers), 0, 0) + q[12:qend]
        for rdata in answers:
            out += b"\xc0\x0c" + struct.pack("!HHIH", qtype, 1, 60, len(rdata)) + rdata
        return out


def read_frame(conn, buf):
    while len(buf) < 4 or len(buf) < 4 + struct.unpack("!I", buf[:4])[0]:
        data = conn.recv(65536)
        if not data:
            return None, buf
        buf += data
    n = struct.unpack("!I", buf[:4])[0]
    return buf[4 : 4 + n], buf[4 + n :]


def main():
    ap = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    ap.add_argument("--sock", required=True, help="unix socket to listen on (QEMU connects)")
    ap.add_argument("--ctl", required=True, help="directory of the files dns64, nat64 and ra")
    ap.add_argument("--log", required=True, help="file that gets one line per packet acted on")
    ap.add_argument("--mac", default="52:54:00:64:00:01")
    ap.add_argument("--link-local", default="fe80::1", help="the router's address in the advertisements")
    ap.add_argument("--gateway", default="2001:db8:64::1", help="a global address of the peer")
    ap.add_argument("--dns", default="2001:db8:64::53")
    ap.add_argument("--ra-prefix", default="2001:db8:64:100::/64", help="the /64 of the session")
    ap.add_argument("--prefix", default="64:ff9b::/96", help="the NAT64 prefix of the operator")
    args = ap.parse_args()
    peer = Peer(args)
    try:
        os.unlink(args.sock)
    except FileNotFoundError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(args.sock)
    srv.listen(1)
    print("ready", flush=True)
    while True:
        conn, _ = srv.accept()
        buf = b""
        try:
            while True:
                for out in peer.tick():
                    conn.sendall(struct.pack("!I", len(out)) + out)
                r, _, _ = select.select([conn], [], [], 1.0)
                if not r:
                    continue
                frame, buf = read_frame(conn, buf)
                if frame is None:
                    break
                for out in peer.handle(frame):
                    conn.sendall(struct.pack("!I", len(out)) + out)
        except OSError:
            pass
        finally:
            conn.close()


if __name__ == "__main__":
    main()
