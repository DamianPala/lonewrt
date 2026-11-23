#!/usr/bin/env python3
"""Drive one QEMU guest of the VM bench (run with python3 -I, standard library only).

Every subcommand takes --run DIR, the guest's run directory: disk.img (the guest's disk), the
sockets QEMU listens on (console.sock, monitor.sock, modem.sock), qemu.pid, ssh_port, console.log
(everything the guest printed on ttyS0) and markers.tsv (host time of every LWVM-MARK line).

  start       boot QEMU in the background (KVM, user-mode networking only, nothing needs root)
  wait-ready  follow the console until this boot's LWVM-READY line, or cut the power on a marker
  sh          run a shell script in the guest over the serial console, print output, exit with rc
  link        set the wwan NIC's link up or down (QEMU monitor set_link)
  recv        take one line from the guest's unlogged xfer UART (start --xfer) into a 0600 file
  banner      read the SSH banner through the host port forwarded to LAN:22
  kill        power cut: SIGKILL to QEMU, the disk keeps what reached it
  stop        stop QEMU (SIGTERM, then SIGKILL)
"""

import argparse
import os
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import time

WWAN_NET = "10.0.3.0/24"
WWAN_GW = "10.0.3.2"


def run_path(run, name):
    return os.path.join(run, name)


def read_pid(run):
    try:
        with open(run_path(run, "qemu.pid"), encoding="ascii") as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None


def alive(pid):
    if pid is None:
        return False
    try:
        with open(f"/proc/{pid}/stat", encoding="ascii") as f:
            return f.read().split(") ", 1)[1][0] != "Z"
    except (OSError, IndexError):
        return False


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def connect_unix(path, timeout):
    deadline = time.monotonic() + timeout
    while True:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.connect(path)
            return s
        except OSError:
            s.close()
            if time.monotonic() > deadline:
                raise
            time.sleep(0.1)


def lan_addresses(lan_ip):
    parts = lan_ip.split(".")
    if len(parts) != 4:
        sys.exit(f"vm: bad LAN address {lan_ip!r}")
    net = ".".join(parts[:3])
    host = f"{net}.254" if parts[3] == "2" else f"{net}.2"
    return f"{net}.0/24", host


def link_nic(a):
    """The NIC that joins two guests: a unix stream socket, the router's end listens."""
    server = a.link_role == "server"
    return [
        "-netdev",
        f"stream,id=lanlink,addr.type=unix,addr.path={a.link_sock},server={'on' if server else 'off'}"
        + ("" if server else ",reconnect-ms=1000"),
        "-device",
        "virtio-net-pci,netdev=lanlink,id=link-nic,"
        f"mac=52:54:00:52:48:{'03' if server else '10'},addr=0x5",
    ]


def nic_args(a, ssh_port, lan_net, lan_host):
    if a.guest:
        return link_nic(a)
    # with --internet the wwan side is user-mode NAT to the real internet; without it nothing leaves
    wwan_restrict = "off" if a.internet else "on"
    nics = [
        "-netdev",
        f"user,id=lan,restrict=on,net={lan_net},host={lan_host},"
        f"hostfwd=tcp:127.0.0.1:{ssh_port}-{a.lan_ip}:22",
        "-device",
        "virtio-net-pci,netdev=lan,id=lan-nic,mac=52:54:00:52:48:01,addr=0x3",
        "-netdev",
        f"user,id=wwan,restrict={wwan_restrict},net={WWAN_NET},host={WWAN_GW},dhcpstart=10.0.3.15",
        "-device",
        "virtio-net-pci,netdev=wwan,id=wwan-nic,mac=52:54:00:52:48:02,addr=0x4",
    ]
    return nics + (link_nic(a) if a.link_role else [])


def cmd_start(a):
    run = a.run
    if a.guest:
        a.no_modem = True
        a.lan_ip = a.lan_ip or "0.0.0.0"
        if not a.link_role:
            sys.exit("vm: --guest needs --link-role and --link-sock")
    elif not a.lan_ip:
        sys.exit("vm: start needs --lan-ip (or --guest)")
    if a.link_role and not a.link_sock:
        sys.exit("vm: --link-role needs --link-sock")
    if alive(read_pid(run)):
        sys.exit(f"vm: QEMU already running for {run}")
    for name in ("console.sock", "monitor.sock", "modem.sock", "xfer.sock", "qemu.pid"):
        try:
            os.unlink(run_path(run, name))
        except FileNotFoundError:
            pass
    qemu = shutil.which("qemu-system-x86_64") or sys.exit("vm: qemu-system-x86_64 not found")
    ssh_port = free_port()
    lan_net, lan_host = lan_addresses(a.lan_ip)
    argv = [
        qemu,
        "-enable-kvm",
        "-cpu",
        "host",
        "-m",
        str(a.mem),
        "-smp",
        "1",
        "-nodefaults",
        "-no-user-config",
        "-display",
        "none",
        "-name",
        "lwvm-" + os.path.basename(run),
        "-drive",
        f"file={run_path(run, 'disk.img')},format=raw,if=virtio,cache=writeback",
        "-chardev",
        f"socket,id=con,path={run_path(run, 'console.sock')},server=on,wait=off,"
        f"logfile={run_path(run, 'console.log')},logappend=on",
        "-serial",
        "chardev:con",
    ]
    if not a.no_modem:
        argv += [
            "-chardev",
            f"socket,id=modem,path={run_path(run, 'modem.sock')},server=on,wait=off",
            "-serial",
            "chardev:modem",
        ]
    if a.xfer:
        # a UART nothing is logged from: the way a secret leaves the guest without reaching a log
        argv += [
            "-chardev",
            f"socket,id=xfer,path={run_path(run, 'xfer.sock')},server=on,wait=off",
            "-serial",
            "chardev:xfer",
        ]
    argv += nic_args(a, ssh_port, lan_net, lan_host) + [
        "-monitor",
        f"unix:{run_path(run, 'monitor.sock')},server=on,wait=off",
        "-pidfile",
        run_path(run, "qemu.pid"),
        "-daemonize",
        "-D",
        run_path(run, "qemu.log"),
    ]
    with open(run_path(run, "ssh_port"), "w", encoding="ascii") as f:
        f.write(f"{ssh_port}\n")
    res = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True)
    if res.returncode != 0:
        sys.exit(f"vm: QEMU failed to start: {res.stderr.strip()}")
    print(
        f"started pid {read_pid(run)} ssh 127.0.0.1:{ssh_port} lan {a.lan_ip}"
        + (" no-modem" if a.no_modem else "")
    )


def known_boots(run):
    try:
        with open(run_path(run, "boot_ids"), encoding="ascii") as f:
            return set(f.read().split())
    except FileNotFoundError:
        return set()


def power_cut(run):
    pid = read_pid(run)
    if pid is not None and alive(pid):
        os.kill(pid, signal.SIGKILL)
        for _ in range(100):
            if not alive(pid):
                break
            time.sleep(0.05)


def drain_markers(con, buf):
    """Markers the guest printed between the trigger marker and the power cut (still buffered)."""
    con.settimeout(0.2)
    while True:
        try:
            data = con.recv(65536)
        except (TimeoutError, OSError):
            break
        if not data:
            break
        buf += data
    return re.findall(r"LWVM-MARK ([^\r\n]+)", buf.decode("ascii", "replace"))


def cmd_wait_ready(a):
    """Follow the console until a new LWVM-READY line, or cut the power after a marker."""
    run = a.run
    seen = known_boots(run)
    con = connect_unix(run_path(run, "console.sock"), 10)
    con.settimeout(0.05)
    deadline = time.monotonic() + a.timeout
    buf = b""
    pid = read_pid(run)
    with open(run_path(run, "markers.tsv"), "a", encoding="ascii") as marks:
        while time.monotonic() < deadline:
            if not alive(pid):
                sys.exit("vm: QEMU exited while waiting for the guest")
            try:
                data = con.recv(65536)
            except TimeoutError:
                continue
            if not data:
                sys.exit("vm: console closed")
            buf += data
            *lines, buf = buf.split(b"\n")
            for idx, raw in enumerate(lines):
                line = raw.decode("ascii", "replace").strip("\r")
                m = re.search(r"LWVM-MARK (.+)$", line)
                if m:
                    marks.write(f"{time.time():.3f}\t{m.group(1).strip()}\n")
                    marks.flush()
                    if a.kill_at and m.group(1).strip() == a.kill_at:
                        time.sleep(a.kill_delay)
                        power_cut(run)
                        print(f"power cut {a.kill_delay:.3f} s after marker '{a.kill_at}'")
                        late = drain_markers(con, b"\n".join(lines[idx + 1 :] + [buf]))
                        print("markers printed before the cut: " + (", ".join(late) or "none"))
                        return
                m = re.search(r"LWVM-READY ([0-9a-f-]+)", line)
                if m and m.group(1) not in seen:
                    if a.kill_at:
                        sys.exit(f"vm: boot finished without marker '{a.kill_at}', no power cut")
                    with open(run_path(run, "boot_ids"), "a", encoding="ascii") as f:
                        f.write(m.group(1) + "\n")
                    print(f"ready boot_id {m.group(1)}")
                    return
    what = f"marker '{a.kill_at}'" if a.kill_at else "LWVM-READY"
    sys.exit(f"vm: no {what} within {a.timeout} s (see {run_path(run, 'console.log')})")


def guest_sh(run, script, timeout):
    """Run script in the guest's console shell; return (rc, output). rc 124 = no answer in time."""
    if "\t" in script:
        sys.exit("vm: no tabs in guest scripts (the console shell would complete them)")
    tok = secrets.token_hex(4)
    # markers are assembled by printf in the guest, so the echoed command line never matches them
    payload = (
        f"cat >/tmp/lwvm-{tok}.sh <<'LWVM_EOF_{tok}'\n{script}\nLWVM_EOF_{tok}\n"
        f"sh /tmp/lwvm-{tok}.sh </dev/null >/tmp/lwvm-{tok}.out 2>&1; "
        f"printf 'LWVM%s-{tok}-%s\\n' B $?; cat /tmp/lwvm-{tok}.out; printf 'LWVM%s-{tok}\\n' E; "
        f"rm -f /tmp/lwvm-{tok}.sh /tmp/lwvm-{tok}.out\n"
    )
    con = connect_unix(run_path(run, "console.sock"), 10)
    con.settimeout(0.2)
    deadline = time.monotonic() + timeout
    # Enter first and wait for the prompt: after a boot the console sits in askfirst, and whatever
    # is typed before login starts the shell is thrown away
    con.sendall(b"\r")
    buf = b""
    while b"# " not in buf and time.monotonic() < deadline:
        try:
            data = con.recv(65536)
        except TimeoutError:
            continue
        if not data:
            break
        buf += data
    con.sendall(payload.encode())
    pattern = re.compile(rf"LWVMB-{tok}-(\d+)\r?\n(.*?)LWVME-{tok}".encode(), re.S)
    buf = b""
    while time.monotonic() < deadline:
        try:
            data = con.recv(65536)
        except TimeoutError:
            continue
        if not data:
            break
        buf += data
        m = pattern.search(buf)
        if m:
            con.close()
            out = m.group(2).replace(b"\r\n", b"\n").decode("utf-8", "replace")
            return int(m.group(1)), out
    con.close()
    return 124, buf.decode("utf-8", "replace")[-2000:]


def cmd_sh(a):
    script = a.script if a.script != "-" else sys.stdin.read()
    rc, out = guest_sh(a.run, script, a.timeout)
    if rc == 124:
        print(
            f"vm: no answer from the guest console within {a.timeout} s; tail:\n{out}",
            file=sys.stderr,
        )
    sys.stdout.write(out)
    sys.exit(rc)


def cmd_link(a):
    mon = connect_unix(run_path(a.run, "monitor.sock"), 5)
    mon.settimeout(1)
    mon.sendall(f"set_link wwan-nic {a.state}\n".encode())
    time.sleep(0.3)
    try:
        reply = mon.recv(65536).decode("ascii", "replace")
    except TimeoutError:
        reply = ""
    mon.close()
    if "rror" in reply:
        sys.exit(f"vm: set_link failed: {reply.strip()}")
    print(f"wwan link {a.state}")


def cmd_banner(a):
    with open(run_path(a.run, "ssh_port"), encoding="ascii") as f:
        port = int(f.read())
    deadline = time.monotonic() + a.timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=3) as s:
                line = s.recv(256).decode("ascii", "replace").splitlines()[0].strip()
            if line.startswith("SSH-"):
                print(line)
                return
        except OSError:
            pass
        time.sleep(1)
    sys.exit(f"vm: no SSH banner on 127.0.0.1:{port} within {a.timeout} s")


def write_private(path, lines):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(b"\n".join(lines) + b"\n")
    os.chmod(path, 0o600)


def cmd_recv(a):
    """Take what the guest writes to the xfer UART into a 0600 file: its first line, or with --end
    every line up to a line that is that marker. Prints how much came, never what."""
    end = a.end.encode() if a.end else None
    con = connect_unix(run_path(a.run, "xfer.sock"), 10)
    con.settimeout(0.5)
    deadline = time.monotonic() + a.timeout
    buf = b""
    got = []
    while time.monotonic() < deadline:
        try:
            data = con.recv(65536)
        except TimeoutError:
            continue
        if not data:
            break
        buf += data
        *lines, buf = buf.split(b"\n")
        for raw in lines:
            line = raw.strip(b"\r\0 ")
            if end is not None and line == end:
                write_private(a.out, got)
                print(f"received {len(got)} lines")
                return
            if line and end is None:
                write_private(a.out, [line])
                print(f"received {len(line)} bytes")
                return
            if line:
                got.append(line)
    sys.exit(f"vm: nothing complete from the xfer UART within {a.timeout} s")


def cmd_kill(a):
    power_cut(a.run)
    print("power cut")


def cmd_stop(a):
    pid = read_pid(a.run)
    if pid is not None and alive(pid):
        os.kill(pid, signal.SIGTERM)
        for _ in range(60):
            if not alive(pid):
                break
            time.sleep(0.05)
        power_cut(a.run)


def main():
    ap = argparse.ArgumentParser(description=(__doc__ or "vm").splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("start")
    p.add_argument("--lan-ip", help="the router's LAN address (not for --guest)")
    p.add_argument(
        "--no-modem", action="store_true", help="no second UART: no AT port in the guest"
    )
    p.add_argument("--mem", type=int, default=256)
    p.add_argument("--internet", action="store_true", help="wwan NIC with NAT to the real internet")
    p.add_argument("--xfer", action="store_true", help="an extra, unlogged UART (see recv)")
    p.add_argument("--guest", action="store_true", help="a small LAN guest: only the link NIC")
    p.add_argument("--link-role", choices=("server", "client"), help="add the guest-to-guest NIC")
    p.add_argument("--link-sock", help="unix socket path of the guest-to-guest NIC")
    p.set_defaults(fn=cmd_start)
    p = sub.add_parser("recv")
    p.add_argument("--timeout", type=float, default=60)
    p.add_argument("--out", required=True, help="file for what the guest sends (0600)")
    p.add_argument("--end", help="collect lines up to this marker line instead of the first line")
    p.set_defaults(fn=cmd_recv)
    p = sub.add_parser("wait-ready")
    p.add_argument("--timeout", type=float, default=180)
    p.add_argument("--kill-at", help="LWVM-MARK text after which to cut the power")
    p.add_argument("--kill-delay", type=float, default=0.0)
    p.set_defaults(fn=cmd_wait_ready)
    p = sub.add_parser("sh")
    p.add_argument("--timeout", type=float, default=60)
    p.add_argument("script", help="shell script for the guest, - for stdin")
    p.set_defaults(fn=cmd_sh)
    p = sub.add_parser("link")
    p.add_argument("state", choices=("on", "off"))
    p.set_defaults(fn=cmd_link)
    p = sub.add_parser("banner")
    p.add_argument("--timeout", type=float, default=60)
    p.set_defaults(fn=cmd_banner)
    sub.add_parser("kill").set_defaults(fn=cmd_kill)
    sub.add_parser("stop").set_defaults(fn=cmd_stop)
    for p in sub.choices.values():
        p.add_argument("--run", required=True, help="the guest's run directory")
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
