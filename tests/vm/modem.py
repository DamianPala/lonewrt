#!/usr/bin/env python3
"""Stand-in for the MF289F AT port, served to the VM over QEMU's second UART (guest /dev/ttyS1).

Run with `python3 -I`, standard library only. QEMU listens on a unix socket (chardev server); this
process connects to it, answers AT commands the way the real modem does (CRLF framing, no echo,
`+ZSNT: 6,0,0` style lines, OK/ERROR), and reconnects whenever QEMU is killed or restarted, so the
modem state survives router reboots and power cuts like modem NVRAM does.

Files (all in --dir):
  init.json   optional seed for the state, read once at start (same keys as state.json)
  state.json  current modem state, rewritten after every change (read it in tests)
  ctl.json    live knobs, re-read before every command:
              {"hang": true}            no answer at all (sms_tool runs into its timeout)
              {"cpin": "SIM PIN"}       AT+CPIN? answer; "ERROR" gives +CME ERROR: 10
              {"delay": 2}              seconds before every answer
              {"overrides": {"AT+ZSNT?": "HANG" | "OK" | "ERROR" | ["line", ...]}}
  at.log      one line per command received: monotonic seconds, command, how it was answered
"""

import argparse
import json
import os
import socket
import sys
import time

DEFAULT_STATE = {
    "zsnt": [6, 0, 0],
    "lte_mask": "88080085",
    "other_mask": "2000000680380",
    "cpin": "READY",
    "imsi": "297020000000001",
    "cpms_mem": ["ME", "ME", "SR"],
    "cpms_used": [25, 25, 0],
    "cpms_total": 100,
}


class Modem:
    def __init__(self, workdir):
        self.dir = workdir
        self.state = dict(DEFAULT_STATE)
        seed = self._read_json("init.json")
        self.state.update(seed)
        self._save()

    def _path(self, name):
        return os.path.join(self.dir, name)

    def _read_json(self, name):
        try:
            with open(self._path(name), encoding="utf-8") as f:
                data = json.load(f)
        except FileNotFoundError:
            return {}
        except (OSError, ValueError) as exc:
            print(f"modem: ignoring unreadable {name}: {exc}", file=sys.stderr)
            return {}
        return data if isinstance(data, dict) else {}

    def _save(self):
        tmp = self._path("state.json.tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.state, f, indent=1, sort_keys=True)
        os.replace(tmp, self._path("state.json"))

    def _log(self, cmd, how):
        with open(self._path("at.log"), "a", encoding="utf-8") as f:
            f.write(f"{time.monotonic():.3f}\t{cmd}\t{how}\n")

    def answer(self, cmd):
        """Return the bytes to send for one command line, or None for no answer."""
        ctl = self._read_json("ctl.json")
        override = ctl.get("overrides", {}).get(cmd)
        if ctl.get("hang") or override == "HANG":
            self._log(cmd, "HANG")
            return None
        if override is not None:
            lines, ok = self._override(override)
        else:
            lines, ok = self._handle_compound(cmd, ctl)
        delay = ctl.get("delay", 0)
        if isinstance(delay, (int, float)) and delay > 0:
            time.sleep(delay)
        self._log(cmd, "OK" if ok is True else ok)
        out = "".join(f"\r\n{line}\r\n" for line in lines)
        if ok is True:
            out += "\r\nOK\r\n"
        elif ok:
            out += f"\r\n{ok}\r\n"
        return out.encode("ascii", "replace")

    @staticmethod
    def _override(value):
        if value == "OK":
            return [], True
        if value == "ERROR":
            return [], "ERROR"
        if isinstance(value, list):
            return [str(v) for v in value], True
        return [str(value)], True

    def _handle_compound(self, cmd, ctl):
        """`AT+CSQ;+COPS?` runs each part in turn; the first failing part ends the answer."""
        lines = []
        for i, part in enumerate(cmd.split(";")):
            part = part.strip()
            if not part:
                continue
            sub_lines, ok = self._handle(part if i == 0 else "AT" + part, ctl)
            lines += sub_lines
            if ok is not True:
                return lines, ok
        return lines, True

    def _handle(self, cmd, ctl):
        up = cmd.upper()
        s = self.state
        if up.startswith(("AT+COPS=", "AT+CREG=")):
            return [], True
        if up == "AT+CREG?":
            return ['+CREG: 2,1,"1F4","3A2B1C",7'], True
        if up in ("AT", "ATE0", "ATE1", "AT+CMGF=0", "AT+CMGF=1") or up.startswith("AT+CMGD="):
            return [], True
        if up == "ATI":
            return ["Manufacturer: ZTE CORPORATION", "Model: MF289F (QEMU stand-in)"], True
        if up == "AT+ZSNT?":
            return ["+ZSNT: " + ",".join(str(v) for v in s["zsnt"])], True
        if up.startswith("AT+ZSNT="):
            return self._set_zsnt(cmd[len("AT+ZSNT=") :])
        if up == "AT+ZNLOCKBAND?":
            return [f"+ZNLOCKBAND: {s['lte_mask']},{s['other_mask']}"], True
        if up.startswith("AT+ZNLOCKBAND="):
            return self._set_bands(cmd[len("AT+ZNLOCKBAND=") :])
        if up == "AT+CPIN?":
            return self._cpin(ctl.get("cpin", s["cpin"]))
        if up == "AT+CIMI":
            return [s["imsi"]], True
        if up == "AT+CPMS?":
            return [self._cpms_query()], True
        if up.startswith("AT+CPMS="):
            return self._set_cpms(cmd[len("AT+CPMS=") :])
        if up.startswith("AT+CMGL"):
            return [], True
        if up == "AT+CSQ":
            return ["+CSQ: 20,99"], True
        if up == "AT+COPS?":
            return ['+COPS: 0,0,"T-Mobile ME",7'], True
        return [], "ERROR"

    def _set_zsnt(self, args):
        try:
            vals = [int(v) for v in args.split(",")]
        except ValueError:
            return [], "ERROR"
        if len(vals) != 3:
            return [], "ERROR"
        self.state["zsnt"] = vals
        self._save()
        return [], True

    def _set_bands(self, args):
        parts = args.split(",")
        if len(parts) != 4 or parts[0] != "1":
            return [], "ERROR"
        try:
            mask = int(parts[2], 16)
        except ValueError:
            return [], "ERROR"
        self.state["lte_mask"] = format(mask, "x")
        self._save()
        return [], True

    @staticmethod
    def _cpin(value):
        if value == "ERROR":
            return [], "+CME ERROR: 10"
        return [f"+CPIN: {value}"], True

    def _cpms_query(self):
        s = self.state
        fields = [f'"{m}",{u},{s["cpms_total"]}' for m, u in zip(s["cpms_mem"], s["cpms_used"])]
        return "+CPMS: " + ",".join(fields)

    def _set_cpms(self, args):
        mems = [a.strip().strip('"').upper() for a in args.split(",")]
        if not 1 <= len(mems) <= 3 or any(m not in ("ME", "SM", "SR", "MT") for m in mems):
            return [], "+CME ERROR: 302"
        s = self.state
        for i, mem in enumerate(mems):
            s["cpms_mem"][i] = mem
        self._save()
        counts = []
        for u in s["cpms_used"]:
            counts += [str(u), str(s["cpms_total"])]
        return ["+CPMS: " + ",".join(counts)], True


def serve(conn, modem):
    """Answer commands on one QEMU connection until it closes."""
    buf = b""
    while True:
        try:
            data = conn.recv(4096)
        except OSError:
            return
        if not data:
            return
        buf += data
        while True:
            cut = min((i for i in (buf.find(b"\r"), buf.find(b"\n")) if i >= 0), default=-1)
            if cut < 0:
                break
            line, buf = buf[:cut], buf[cut + 1 :]
            cmd = line.decode("ascii", "replace").strip()
            # the guest tty may echo our own answers back; only command lines get an answer
            if not cmd.upper().startswith("AT"):
                continue
            reply = modem.answer(cmd)
            if reply:
                try:
                    conn.sendall(reply)
                except OSError:
                    return


def main():
    ap = argparse.ArgumentParser(description=(__doc__ or "modem").splitlines()[0])
    ap.add_argument("--socket", required=True, help="QEMU chardev unix socket to connect to")
    ap.add_argument("--dir", required=True, help="directory for init/state/ctl json and at.log")
    args = ap.parse_args()
    modem = Modem(args.dir)
    while True:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            conn.connect(args.socket)
        except OSError:
            conn.close()
            time.sleep(0.1)
            continue
        with conn:
            serve(conn, modem)
        time.sleep(0.1)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
