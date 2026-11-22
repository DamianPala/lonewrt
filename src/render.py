"""Render the rootfs overlay (ImageBuilder FILES) for one build profile.

Run by build.sh as `python3 -I src/render.py ...`. Parses profiles/<name>.conf without executing it
(SPEC R3), resolves empty passwords from the password card or draws new ones (SPEC R33), copies
src/files, fills in the @KEY@ placeholders, adds the weekly balance cron job when the profile has
notifications and a balance threshold (SPEC R35) and the heartbeat job when the profile has a ping
address (SPEC R42), the profile's SSH key files merged with its SSH_KEYS (SPEC R61) and
/etc/lw-build with the release version of the VERSION file (SPEC R3b, R7b), fills an empty TIMEZONE
from ZONENAME with the configurator's zone table (SPEC R3c), sets file modes and
checks every shell script with busybox `sh -n` (SPEC R6).
Errors name the key, line or file, never a profile value.
"""

import argparse
import base64
import hashlib
import json
import re
import secrets
import shutil
import struct
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path

MAY_BE_EMPTY = {
    "WIFI_KEY",
    "ROOT_PASSWORD",
    "ROOT_PASSWORD_HASH",
    "WWAN_APN",
    "WWAN_AUTH",
    "WWAN_USERNAME",
    "WWAN_PASSWORD",
    "LTE_BANDS",
    "WG_PRIVATE_KEY",
    "WG_ADDRESS",
    "WG_PEER_PUBLIC_KEY",
    "WG_ENDPOINT_HOST",
    "WG_ENDPOINT_PORT",
    "WG_ALLOWED_IPS",
    "WG_KEEPALIVE",
    "TG_BOT_TOKEN",
    "TG_CHAT_ID",
    "LOW_BALANCE",
    "HC_PING_URL",
    "SMS_ADMINS",
    "SSH_KEYS",
    "TIMEZONE",
}
NOTIFY_KEYS = ("TG_BOT_TOKEN", "TG_CHAT_ID")
# Weekly balance check (SPEC R35), only in images with notifications and a threshold
BALANCE_CRON = "0 10 * * 1 /usr/sbin/lw-notify balance"
# Heartbeat to healthchecks.io every 5 minutes (SPEC R42), only in images whose profile has the URL
HEARTBEAT_CRON = "*/5 * * * * /usr/sbin/lw-heartbeat"
REQUIRED_WHEN_WG_ENABLED = (
    "WG_PRIVATE_KEY",
    "WG_ADDRESS",
    "WG_PEER_PUBLIC_KEY",
    "WG_ENDPOINT_HOST",
)

IPV4 = r"(?:(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])"
CIDR_LIST = rf"{IPV4}/[0-9]{{1,2}}(?: {IPV4}/[0-9]{{1,2}})*"
WG_KEY = r"[A-Za-z0-9+/]{43}="
PASSWORD = r"[\x20-\x7e]{8,63}"
# What a non-empty value must look like; keys not listed take any text without a single quote.
FORMATS = {
    "HOSTNAME": r"[A-Za-z0-9][A-Za-z0-9-]{0,62}",
    "LAN_IP": IPV4,
    "WIFI_SSID": r"[^\x00-\x1f]{1,32}",
    "WIFI_KEY": PASSWORD,
    "WIFI_COUNTRY": r"[A-Z]{2}",
    "WIFI_CHANNEL_2G": r"auto|[0-9]{1,3}",
    "WIFI_CHANNEL_5G": r"auto|[0-9]{1,3}",
    "WIFI_HTMODE_2G": r"[A-Z0-9+-]{2,10}",
    "WIFI_HTMODE_5G": r"[A-Z0-9+-]{2,10}",
    "ROOT_PASSWORD": PASSWORD,
    "ROOT_PASSWORD_HASH": r"\$[A-Za-z0-9./$]+",
    "WWAN_AUTH": r"none|pap|chap|both",
    "LTE_BANDS": r"[0-9]{1,2}(?:,[0-9]{1,2})*",
    "WG_ENABLED": r"[01]",
    "WG_PRIVATE_KEY": WG_KEY,
    "WG_ADDRESS": CIDR_LIST,
    "WG_PEER_PUBLIC_KEY": WG_KEY,
    "WG_ENDPOINT_HOST": r"[A-Za-z0-9.:-]+",
    "WG_ENDPOINT_PORT": r"[0-9]{1,5}",
    "WG_ALLOWED_IPS": CIDR_LIST,
    "WG_KEEPALIVE": r"[0-9]{1,3}",
    "TG_BOT_TOKEN": r"[0-9]{5,15}:[A-Za-z0-9_-]{30,64}",
    "TG_CHAT_ID": r"-?[0-9]{1,20}",
    # in the currency of the operator preset (SPEC R47b)
    "LOW_BALANCE": r"[0-9]{1,4}(?:\.[0-9]{1,2})?",
    # starts every SMS reply (SPEC R48); it begins with a letter or digit because the reply is the
    # text argument of sms_tool, which would take a leading "-" for an option
    "ROUTER_NAME": r"[A-Za-z0-9][A-Za-z0-9 -]{0,19}",
    # a secret: https only, and no quote, backslash, space or other character a shell could take
    # (the value lands inside single quotes of zz-lw-config)
    "HC_PING_URL": r"https://[A-Za-z0-9._~:/?&=%+-]{4,300}",
    # private data: comma list of numbers, each with an optional + and 6 to 15 digits, no spaces
    # (SPEC R46); written verbatim to uci lonewrt.notify.sms_admins
    "SMS_ADMINS": r"\+?[0-9]{6,15}(?:,\+?[0-9]{6,15})*",
    # REBOOT by SMS (SPEC R46b): minutes the SMSC time may be old, restarts per day; positive
    # integers of up to 4 digits, written to uci lonewrt.notify.sms_reboot_max_age / _max_day
    "SMS_REBOOT_MAX_AGE_MIN": r"[1-9][0-9]{0,3}",
    "SMS_REBOOT_MAX_PER_DAY": r"[1-9][0-9]{0,3}",
    # seconds until watchcat restarts wwan (SPEC R14a); the range is in RANGES
    "LINK_RESTART_AFTER_S": r"[1-9][0-9]{0,3}",
}
# Inclusive range of a numeric key, checked after FORMATS. LINK_RESTART_AFTER_S (SPEC R14a, D79):
# the lower bound is two ping periods of the watchcat entry (60 s), the upper bound keeps the
# interface restart ahead of the first router restart of wwan-recover (6 cycles of 5 min), also
# for a failure already there at boot.
RANGES = {"LINK_RESTART_AFTER_S": (120, 900)}
# Keys that take one of a few words (SPEC R3, R29c); an exact match, so DEBUG is refused.
CHOICES = {"LOG_LEVEL": ("info", "debug")}
LINE = re.compile(r"([A-Z][A-Z0-9_]*)='([^']*)'")
PLACEHOLDER = re.compile(r"@([A-Z][A-Z0-9_]*)@")
# SPEC R3b: the release version, MAJOR.MINOR.PATCH with an optional -prerelease (no leading zeros in
# the numbers); ASCII only, one line
VERSION_FORMAT = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?"
)
KEY_FILES = ("dropbear_ed25519_host_key", "dropbear_rsa_host_key")
SSH_KEY_TYPES = ("ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256")
# A comment is printable text (a control character would break the line of authorized_keys)
SSH_COMMENT = re.compile(r"[^\x00-\x1f\x7f]*")
# Script locations whose files may lack a shebang because they are sourced
SOURCED_DIRS = ("etc/uci-defaults/", "etc/hotplug.d/", "usr/lib/lw/")
PASSWORD_ALPHABET = "abcdefghijkmnpqrstuvwxyz23456789"  # gitleaks:allow (an alphabet, not a key)
# The data block of configurator/index.html, whose "zones" table (LuCI's, R56f) fills an empty
# TIMEZONE (R3c)
PAGE_DATA = re.compile(r'<script type="application/json" id="lw-data">(.*?)</script>', re.DOTALL)


class RenderError(Exception):
    """A problem the owner must fix in the profile, the card or the sources."""


def parse_profile(path: Path) -> dict[str, str]:
    if not path.is_file():
        raise RenderError(f"profile {path} does not exist")
    values: dict[str, str] = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = LINE.fullmatch(line)
        if not match:
            raise RenderError(
                f"{path.name} line {number}: expected KEY='value' with no ' inside the value"
            )
        key, value = match.groups()
        if key in values:
            raise RenderError(f"{path.name} line {number}: key {key} appears twice")
        values[key] = value
    return values


def allowed_hint(key: str) -> str:
    """What a stopped build tells the owner about the values a key takes."""
    if key in RANGES:
        return f"; use a whole number from {RANGES[key][0]} to {RANGES[key][1]}"
    if key in CHOICES:
        return f"; use {' or '.join(CHOICES[key])}"
    return ""


def check_value(key: str, value: str, name: str) -> None:
    if not value and key not in MAY_BE_EMPTY:
        # a key with a fixed list of values names it also when it is empty
        hint = allowed_hint(key) if key in CHOICES else ""
        raise RenderError(f"profile {name}: key {key} is empty{hint}")
    pattern = FORMATS.get(key)
    valid = not (value and pattern) or re.fullmatch(pattern, value) is not None
    if valid and value and key in RANGES:
        valid = RANGES[key][0] <= int(value) <= RANGES[key][1]
    if valid and value and key in CHOICES:
        valid = value in CHOICES[key]
    if not valid:
        raise RenderError(f"profile {name}: key {key} has an invalid value{allowed_hint(key)}")


def parse_ssh_entry(entry: str) -> tuple[str, str, str] | None:
    """One entry of SSH_KEYS as (type, base64 data, comment), None when it is malformed (R61).

    Whitespace around the entry and between its fields is dropped, so the line written to the image
    always has single spaces. The data must be strict base64 whose first field, in the SSH wire
    format a 4-byte length and the type name, is the declared type: that catches a swapped type
    and a pasted fragment without parsing the rest of the key.
    """
    fields = entry.split(None, 2)
    if len(fields) < 2 or fields[0] not in SSH_KEY_TYPES:
        return None
    key_type, data = fields[0], fields[1]
    comment = fields[2].strip() if len(fields) == 3 else ""
    # no ';' to test for: the entry is what is left between two of them
    if not SSH_COMMENT.fullmatch(comment):
        return None
    try:
        blob = base64.b64decode(data, validate=True)
        (length,) = struct.unpack(">I", blob[:4])
    except (ValueError, struct.error):  # binascii.Error is a ValueError; so is non-ASCII data
        return None
    # what validate=True lets through differs between Python versions (3.12 drops excess '='), so
    # only the canonical spelling of the bytes counts
    if base64.b64encode(blob).decode() != data:
        return None
    if blob[4 : 4 + length] != key_type.encode():
        return None
    return key_type, data, comment


def parse_ssh_keys(value: str, name: str) -> list[tuple[str, str, str]]:
    """The keys of SSH_KEYS in order, each key (type and data, not the comment) once (R61, D114).

    An empty entry, such as `a;;b`, a leading or a trailing `;`, is malformed like any other bad
    entry: it is most likely a pasted key that lost its text. The error gives the entry's number
    (1-based) and never the entry.
    """
    keys: list[tuple[str, str, str]] = []
    if not value:
        return keys
    for number, entry in enumerate(value.split(";"), 1):
        key = parse_ssh_entry(entry)
        if key is None:
            raise RenderError(
                f"profile {name}: key SSH_KEYS entry {number} is malformed; "
                f"expected <type> <base64 data> [comment], type {', '.join(SSH_KEY_TYPES)}"
            )
        if all(key[:2] != seen[:2] for seen in keys):
            keys.append(key)
    return keys


def validate(values: dict[str, str], required: list[str], name: str) -> None:
    for key in values:
        if key not in required:
            raise RenderError(f"profile {name}: unknown key {key} (not in generic.conf)")
    for key in required:
        if key not in values:
            # a profile older than a new key fails here (R3); say how to bring it up to date
            fix = f"add the line {key}=''" if key in MAY_BE_EMPTY else "copy it from generic.conf"
            raise RenderError(f"profile {name}: key {key} is missing; {fix}")
        check_value(key, values[key], name)
    parse_ssh_keys(values["SSH_KEYS"], name)
    if values["ROOT_PASSWORD"] and values["ROOT_PASSWORD_HASH"]:
        raise RenderError(
            f"profile {name}: keys ROOT_PASSWORD and ROOT_PASSWORD_HASH are both set; use one"
        )
    if values["WG_ENABLED"] == "1":
        for key in REQUIRED_WHEN_WG_ENABLED:
            if not values[key]:
                raise RenderError(f"profile {name}: key {key} is empty but WG_ENABLED is 1")


def read_zones(page: Path | None) -> dict[str, str]:
    if page is None or not page.is_file():
        raise RenderError(f"no zone list: the configurator page {page} is missing")
    match = PAGE_DATA.search(page.read_text(encoding="utf-8"))
    zones = json.loads(match.group(1)).get("zones") if match else None
    if not isinstance(zones, dict) or not zones:
        raise RenderError(f"no zone list in {page}")
    return zones


def fill_timezone(values: dict[str, str], page: Path | None, name: str) -> bool:
    """An empty TIMEZONE takes the string of ZONENAME from the configurator's table (R3c, D127).

    The page is read only then, so a profile with its own TIMEZONE builds without it. True when
    the string came from the table.
    """
    if values["TIMEZONE"]:
        return False
    zones = read_zones(page)
    if values["ZONENAME"] not in zones:
        raise RenderError(
            f"profile {name}: key TIMEZONE is empty and ZONENAME is not in the configurator's "
            "list of time zones; set TIMEZONE"
        )
    values["TIMEZONE"] = zones[values["ZONENAME"]]
    return True


def notify_state(values: dict[str, str]) -> str:
    """Notifications need both the token and the chat; with only one of them the image runs as
    without them and logs that once at first boot (SPEC R38a)."""
    token, chat = (values[key] for key in NOTIFY_KEYS)
    if token and chat:
        return "on"
    if token or chat:
        return "off (only one of TG_BOT_TOKEN and TG_CHAT_ID is set)"
    return "off"


def add_balance_cron(out: Path, values: dict[str, str]) -> bool:
    """Append the weekly balance job when the profile turns it on (SPEC R35, R36); the generic image
    keeps the crontab of the sources (SPEC R7 table)."""
    if not (values["TG_BOT_TOKEN"] and values["TG_CHAT_ID"] and values["LOW_BALANCE"]):
        return False
    crontab = out / "etc/crontabs/root"
    text = crontab.read_text(encoding="ascii")
    if not text.endswith("\n"):
        text += "\n"
    crontab.write_text(text + BALANCE_CRON + "\n", encoding="ascii")
    return True


def add_heartbeat_cron(out: Path, values: dict[str, str]) -> bool:
    """Append the heartbeat job when the profile has a ping address (SPEC R42); it does not depend
    on the notification keys."""
    if not values["HC_PING_URL"]:
        return False
    crontab = out / "etc/crontabs/root"
    text = crontab.read_text(encoding="ascii")
    if not text.endswith("\n"):
        text += "\n"
    crontab.write_text(text + HEARTBEAT_CRON + "\n", encoding="ascii")
    return True


def read_card(path: Path | None) -> dict[str, str]:
    if path is None or not path.is_file():
        return {}
    card: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        key, sep, value = line.partition("=")
        if sep and key in ("ssid", "wifi", "root") and key not in card:
            card[key] = value
    if card.get("wifi") and not re.fullmatch(PASSWORD, card["wifi"]):
        raise RenderError(f"card {path}: wifi= must be 8-63 printable ASCII characters")
    # a cut or edited card would otherwise give the router a root password like "x"
    if card.get("root") and not re.fullmatch(PASSWORD, card["root"]):
        raise RenderError(f"card {path}: root= must be 8-63 printable ASCII characters")
    return card


def draw_password() -> str:
    groups = ("".join(secrets.choice(PASSWORD_ALPHABET) for _ in range(4)) for _ in range(3))
    return "-".join(groups)


def hash_password(password: str) -> str:
    result = subprocess.run(
        ["openssl", "passwd", "-6", "-stdin"],
        input=password + "\n",
        capture_output=True,
        text=True,
        check=False,
    )
    digest = result.stdout.strip()
    if result.returncode != 0 or not digest.startswith("$6$"):
        raise RenderError(f"openssl passwd -6 failed: {result.stderr.strip()}")
    return digest


def resolve_passwords(values: dict[str, str], card_in: Path | None) -> tuple[str, dict] | None:
    """Fill empty WIFI_KEY and the root hash; return (card text, origin) when a card applies.

    A ROOT_PASSWORD from the profile is hashed here (D73). A card is written when a password is
    drawn, and whenever a card for the profile already exists: then it is rewritten from what the
    image holds (R33b), so it never names a password the image does not have. Drawn values come
    from the old card; a value the profile sets replaces the card's. With only a root hash there
    is no clear root password and the card says so. A hash gets a new salt on every build, as for
    a drawn password: the password stays, the hash not.
    """
    need_wifi = not values["WIFI_KEY"]
    own_root = values["ROOT_PASSWORD"]
    need_root = not own_root and not values["ROOT_PASSWORD_HASH"]
    has_card = card_in is not None and card_in.is_file()
    if own_root:
        values["ROOT_PASSWORD_HASH"] = hash_password(own_root)
    if not (need_wifi or need_root or has_card):
        return None
    old = read_card(card_in)
    origin = {}
    card = {"ssid": values["WIFI_SSID"], "wifi": values["WIFI_KEY"]}
    if need_wifi:
        card["wifi"] = old.get("wifi") or draw_password()
        values["WIFI_KEY"] = card["wifi"]
        origin["wifi"] = "reused from card" if old.get("wifi") else "drawn"
    if own_root:
        card["root"] = own_root
        origin["root"] = "from profile"
    elif need_root:
        card["root"] = old.get("root") or draw_password()
        values["ROOT_PASSWORD_HASH"] = hash_password(card["root"])
        origin["root"] = "reused from card" if old.get("root") else "drawn"
    return card_text(card, values), origin


def card_text(card: dict[str, str], values: dict[str, str]) -> str:
    lines = [f"{key}={card[key]}" for key in ("ssid", "wifi", "root") if key in card]
    lan = values["LAN_IP"]
    country = values["WIFI_COUNTRY"]
    root = (
        "password from the root= line"
        if "root" in card
        else "password behind ROOT_PASSWORD_HASH in the profile (it is not on this card)"
    )
    hints = f"""
LTE router with OpenWrt (ZTE MF289F): passwords and hints

- WiFi: the network name is ssid=, the password is wifi= (the same network on 2.4 and 5 GHz).
- Router panel (LuCI): https://{lan}, user root, {root}.
  The browser warns that the certificate is not trusted. The router signs it itself, so this is expected:
  choose Advanced and continue.
- A reset with the button restores the settings from the image, including the passwords on this card.
- SIM card with a PIN: remove the PIN in a phone, or enter it in LuCI:
  Network > Interfaces > WWAN > Edit > PIN.
- No internet 5 minutes after boot: enter the operator's APN in LuCI:
  Network > Interfaces > WWAN > Edit > APN, then Save & Apply.
- The router works on LTE and sets LTE again at every boot. Only when LTE stays dead after a restart
  does it switch to 2G (EDGE) for a while. A network mode set in LuCI lasts until the next boot.
- When the internet fails, the router first restarts the connection by itself, then, if that does not help, the whole router.
  To turn off the router restarts in LuCI: System > Scheduled Tasks, delete the line with /usr/sbin/wwan-recover.
- SMS: when the modem holds more than 30 messages, the router saves all of them to
  /root/sms-archive/ every day at 04:10 and deletes the oldest, keeping 20.
- To change the WiFi country (now {country}) in LuCI: Network > Wireless > Edit on each radio >
  Advanced Settings > Country Code.
- SSH warns that the host key changed: expected after a flash or a reset with the button, when
  the router makes a new key. Run ssh-keygen -R {lan} and connect again.
"""
    return "\n".join(lines) + "\n" + hints


def read_version(path: Path) -> str:
    """The version of the VERSION file; a missing file or a bad value stops the build (R3b)."""
    if not path.is_file():
        raise RenderError(f"VERSION is missing: {path} must hold the release, for example 0.1.0")
    version = path.read_bytes().decode("utf-8", errors="replace").removesuffix("\n")
    if not VERSION_FORMAT.fullmatch(version):
        shown = version[:40].replace("\n", "\\n")
        raise RenderError(
            f"VERSION is not MAJOR.MINOR.PATCH with an optional -prerelease, for example 0.1.0 "
            f"or 0.2.0-rc.1: got '{shown}' in {path}"
        )
    return version


def src_digest(src: Path) -> str:
    """sha256 over `relative path NUL sha256(content) LF` for every file under src, sorted."""
    outer = hashlib.sha256()
    files = sorted(p for p in src.rglob("*") if p.is_file())
    for path in files:
        rel = path.relative_to(src).as_posix()
        inner = hashlib.sha256(path.read_bytes()).hexdigest()
        outer.update(f"{rel}\0{inner}\n".encode())
    return outer.hexdigest()


def fill_placeholders(out: Path, values: dict[str, str]) -> None:
    for path in sorted(p for p in out.rglob("*") if p.is_file()):
        text = path.read_bytes().decode("utf-8", errors="surrogateescape")
        if not PLACEHOLDER.search(text):
            continue

        def replace(match: re.Match, rel: str = path.relative_to(out).as_posix()) -> str:
            key = match.group(1)
            if key not in values:
                raise RenderError(f"{rel}: placeholder @{key}@ is not a profile key")
            return values[key]

        filled = PLACEHOLDER.sub(replace, text)
        path.write_bytes(filled.encode("utf-8", errors="surrogateescape"))


def folder_key_ids(line: str) -> set[tuple[str, str]]:
    """The (type, data) pairs a line of profiles/<name>/authorized_keys holds; none for a comment or
    a blank line. The line may start with options (`from="..." ssh-ed25519 ...`), so a type is
    searched for as a word; the folder file is the owner's and R61 does not validate it."""
    if line.lstrip().startswith("#"):
        return set()
    return set(re.findall(rf"(?:^|\s)({'|'.join(SSH_KEY_TYPES)})\s+(\S+)", line))


def write_authorized_keys(
    profile_dir: Path, out: Path, ssh_keys: list[tuple[str, str, str]]
) -> bool:
    """Write /etc/dropbear/authorized_keys: the keys of SSH_KEYS, then the lines of the profile
    folder's file whose key is not among them (R61, D114). The same key is the same type and data,
    whatever the comment or options. Folder lines are copied as they are and are not compared
    with each other; with an empty SSH_KEYS the file is copied unchanged, as before R61. With
    neither source there is no file."""
    source = profile_dir / "authorized_keys"
    if not ssh_keys and not source.is_file():
        return False
    target = out / "etc/dropbear/authorized_keys"
    target.parent.mkdir(parents=True, exist_ok=True)
    if not ssh_keys:
        shutil.copyfile(source, target)
        return True
    seen = {key[:2] for key in ssh_keys}
    lines = [" ".join(part for part in key if part) for key in ssh_keys]
    if source.is_file():
        text = source.read_text(encoding="utf-8", errors="surrogateescape")
        lines += [
            line for line in text.removesuffix("\n").split("\n") if not folder_key_ids(line) & seen
        ]
    target.write_text("\n".join(lines) + "\n", encoding="utf-8", errors="surrogateescape")
    return True


def install_key_files(
    profile_dir: Path, out: Path, ssh_keys: list[tuple[str, str, str]]
) -> list[str]:
    installed = ["authorized_keys"] if write_authorized_keys(profile_dir, out, ssh_keys) else []
    for name in KEY_FILES:
        source = profile_dir / name
        if source.is_file():
            target = out / "etc/dropbear" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            installed.append(name)
    if installed:
        (out / "etc/dropbear").chmod(0o700)
    return installed


def has_shebang(path: Path) -> bool:
    with path.open("rb") as handle:
        return handle.read(2) == b"#!"


def is_script(rel: str, path: Path) -> bool:
    if has_shebang(path):
        with path.open("rb") as handle:
            return b"sh" in handle.readline()
    return rel.startswith(SOURCED_DIRS)


def set_dir_modes(out: Path) -> None:
    # ImageBuilder copies FILES with `cp -p`, so these modes land on /, /etc, /usr/sbin ... of the
    # image; a checkout under umask 002 would make them group-writable.
    for path in [out, *(p for p in out.rglob("*") if p.is_dir())]:
        path.chmod(0o700 if path == out / "etc/dropbear" else 0o755)


def set_modes(out: Path) -> list[str]:
    """Set image file modes; return the shell scripts (relative paths) for the syntax check."""
    set_dir_modes(out)
    scripts = []
    for path in sorted(p for p in out.rglob("*") if p.is_file()):
        rel = path.relative_to(out).as_posix()
        if rel.startswith("etc/dropbear/") or rel == "etc/crontabs/root":
            path.chmod(0o600)
        elif rel.startswith("etc/uci-defaults/"):
            # D15: first boot deletes it only from the writable layer; the copy in the read-only
            # image keeps the secrets for whoever holds the image or the router
            path.chmod(0o700)
        elif has_shebang(path):
            path.chmod(0o755)  # executables, e.g. /usr/lib/lw/lw-apn run by the hotplug
        else:
            path.chmod(0o644)  # sourced helpers such as /usr/lib/lw/common.sh, configs
        if is_script(rel, path):
            scripts.append(rel)
    return scripts


def syntax_check(out: Path, scripts: list[str], shell: list[str]) -> None:
    for rel in scripts:
        result = subprocess.run(
            [*shell, "-n", str(out / rel)], capture_output=True, text=True, check=False
        )
        if result.returncode != 0:
            message = result.stderr.strip().replace(str(out) + "/", "")
            raise RenderError(f"syntax error in {rel}: {message}")


def shell_command(rootfs: Path | None) -> list[str]:
    """busybox ash of the OpenWrt rootfs (same parser as the router), else the host's busybox."""
    if rootfs and (rootfs / "bin/busybox").is_file():
        libs = f"{rootfs}/lib:{rootfs}/usr/lib"
        loader = str(rootfs / "lib/ld-musl-x86_64.so.1")
        return [loader, "--library-path", libs, str(rootfs / "bin/busybox"), "sh"]
    host = shutil.which("busybox")
    if host:
        return [host, "sh"]
    raise RenderError("no busybox for sh -n: run ./fetch-deps.sh rootfs or install busybox")


def render(args: argparse.Namespace) -> None:
    template = parse_profile(args.profiles / "generic.conf")
    values = parse_profile(args.profiles / f"{args.name}.conf")
    validate(values, list(template), args.name)
    zone_filled = fill_timezone(values, args.zones, args.name)
    version = read_version(args.version_file)
    card = resolve_passwords(values, args.card_in)
    shell = shell_command(args.rootfs)

    out: Path = args.out
    if out.exists() and any(out.iterdir()):
        raise RenderError(f"output directory {out} is not empty")
    shutil.copytree(args.src / "files", out, dirs_exist_ok=True)
    fill_placeholders(out, values)
    balance = add_balance_cron(out, values)
    heartbeat = add_heartbeat_cron(out, values)
    ssh_keys = parse_ssh_keys(values["SSH_KEYS"], args.name)
    keys = install_key_files(args.profiles / args.name, out, ssh_keys)
    built = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    digest = src_digest(args.src)
    build_id = f"version={version}\nprofile={args.name}\nbuilt={built}\nsrc_sha256={digest}\n"
    (out / "etc/lw-build").write_text(build_id, encoding="ascii")
    scripts = set_modes(out)
    syntax_check(out, scripts, shell)

    notes = [
        f"profile {args.name}, version {version}, src_sha256 {digest[:12]}",
        f"{len(scripts)} scripts pass sh -n ({shell[-2]})",
        f"SSH key files from profile: {', '.join(keys) or 'none'}",
        f"SSH_KEYS: {len(ssh_keys)} keys",
        f"notifications: {notify_state(values)}" + (", weekly balance check" if balance else ""),
        f"heartbeat: {'on' if heartbeat else 'off'}",
        f"TIMEZONE: {'from ZONENAME' if zone_filled else 'from the profile'}",
    ]
    if card and args.card_out:
        args.card_out.write_text(card[0], encoding="utf-8")
        args.card_out.chmod(0o600)
        notes.append("passwords: " + ", ".join(f"{k} {how}" for k, how in card[1].items()))
    for note in notes:
        print(f"render: {note}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description="Render the rootfs overlay for one build profile.")
    parser.add_argument("--name", required=True)
    parser.add_argument("--profiles", type=Path, required=True)
    parser.add_argument("--src", type=Path, required=True)
    parser.add_argument("--version-file", type=Path, required=True, help="the VERSION file")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--card-in", type=Path, help="existing password card to reuse")
    parser.add_argument("--card-out", type=Path, help="where to write the password card")
    parser.add_argument("--rootfs", type=Path, help="OpenWrt rootfs whose busybox checks syntax")
    parser.add_argument("--zones", type=Path, help="configurator page whose zones fill TIMEZONE")
    args = parser.parse_args()
    try:
        render(args)
    except RenderError as error:
        print(f"render: error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
