"""Static checks of configurator/index.html, no browser (SPEC R52, R56, R56e, R57, R58, R56c).

    python3 -I check_page.py PAGE GENERIC_CONF RENDER_PY VERSION_FILE [ZONEINFO_UC]

Every problem is printed as one line that names the key or the construct; exit status 1 when there is
one, else the last line is a short summary. The paths are arguments so that a test can run it on a
scratch copy of generic.conf, of the page or of VERSION and see it fail. ZONEINFO_UC is LuCI's
luci/zoneinfo.uc of the OpenWrt rootfs; with it the page's time zone table must equal it.
"""

import importlib.util
import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

# Hosts an <a> may point to: a plain link the person clicks (R58a), never one that loads by itself.
LINK_HOSTS = {"t.me"}
# Attributes that make the browser load something by itself, on any tag but <a>.
LOADING_ATTRS = {"src", "srcset", "data", "poster", "action", "formaction", "ping", "manifest"}
# Script constructs that call out, and the browser storage R56c rules out.
NETWORK_JS = re.compile(
    r"\b(fetch|XMLHttpRequest|WebSocket|EventSource|sendBeacon|importScripts|Worker|SharedWorker)\b"
    r"|\bimport\s*\("
)
STORAGE_JS = re.compile(
    r"\b(localStorage|sessionStorage|indexedDB|openDatabase|caches)\b|document\.cookie"
)
URL_IN_CODE = re.compile(r"https?://|//[A-Za-z0-9.-]+\.[a-z]{2,}", re.IGNORECASE)
CSS_LOAD = re.compile(r"@import|url\s*\(", re.IGNORECASE)


class Page(HTMLParser):
    """Collects what the checks need: the tags, the scripts and the style text."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.problems: list[str] = []
        self.data: str | None = None
        self.code: list[str] = []
        self.style: list[str] = []
        self.csp = ""
        self.ids: set[str] = set()
        self._in: str | None = None
        self._json = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        a = {k: (v or "") for k, v in attrs}
        if "id" in a:
            self.ids.add(a["id"])
        if tag == "script":
            self._in = "script"
            self._json = a.get("type") == "application/json"
            self._json_id = a.get("id", "")
            if "src" in a:
                self.problems.append(f"<script src={a['src'][:60]}> loads a file")
        elif tag == "style":
            self._in = "style"
        elif tag == "meta" and a.get("http-equiv", "").lower() == "content-security-policy":
            self.csp = a.get("content", "")
        elif tag == "meta" and a.get("http-equiv", "").lower() == "refresh":
            self.problems.append("<meta http-equiv=refresh> navigates by itself")
        self.check_tag(tag, a)

    def check_tag(self, tag: str, a: dict[str, str]) -> None:
        if tag in {
            "img",
            "iframe",
            "frame",
            "object",
            "embed",
            "audio",
            "video",
            "source",
            "track",
            "base",
        }:
            self.problems.append(f"<{tag}> can load a resource")
        if tag == "link" and not (a.get("rel") == "icon" and a.get("href", "").startswith("data:")):
            self.problems.append(f"<link rel={a.get('rel', '')}> loads a file")
        if tag == "a":
            href = a.get("href", "")
            host = re.match(r"https://([^/]+)/", href + "/")
            if "ping" in a or not host or host.group(1) not in LINK_HOSTS:
                self.problems.append(
                    f"<a href={href[:60]}> is not a plain link to {sorted(LINK_HOSTS)}"
                )
            if "noreferrer" not in a.get("rel", ""):
                self.problems.append(f"<a href={href[:60]}> lacks rel=noreferrer")
        else:
            for name in LOADING_ATTRS & a.keys():
                if tag != "script" or name != "src":
                    self.problems.append(f"<{tag} {name}=...> can load a resource")

    def handle_endtag(self, tag: str) -> None:
        if tag in {"script", "style"}:
            self._in = None

    def handle_data(self, data: str) -> None:
        if self._in == "style":
            self.style.append(data)
        elif self._in == "script":
            if self._json:
                self.data = (self.data or "") + data
            else:
                self.code.append(data)


def load_render(path: Path):
    spec = importlib.util.spec_from_file_location("lw_render", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def accepted_values(render, key: str) -> set[str] | None:
    """Every value build.sh accepts for a key with a short fixed list, None when it is not a list."""
    values: set[str] = set()
    if key in render.CHOICES:
        values = set(render.CHOICES[key])
    elif key in render.FORMATS:
        pattern = render.FORMATS[key]
        if re.fullmatch(r"[a-z|]+", pattern):
            values = set(pattern.split("|"))
        elif re.fullmatch(r"\[[0-9]+\]", pattern):
            values = set(pattern[1:-1])
        else:
            return None
    else:
        return None
    if key in render.MAY_BE_EMPTY:
        values.add("")
    return values


def check_fields(
    data: dict, generic: list[str], defaults: dict[str, str], render, problems: list[str]
) -> None:
    fields = data["fields"]
    keys = [f["key"] for f in fields]
    for key in generic:
        if key not in keys:
            problems.append(f"generic.conf has the key {key} that the page lacks")
    for key in keys:
        if key not in generic:
            problems.append(f"the page has the key {key} that generic.conf lacks")
    for key in {k for k in keys if keys.count(k) > 1}:
        problems.append(f"the page has the key {key} more than once")
    common = [k for k in generic if k in keys]
    if common != [k for k in keys if k in generic] and not problems:
        problems.append("the order of the keys on the page differs from generic.conf")
    group_ids = [g["id"] for g in data["groups"]]
    shown = [f["key"] for gid in group_ids for f in fields if f["group"] == gid]
    for f in fields:
        key = f["key"]
        if f["group"] not in group_ids:
            problems.append(f"{key}: group {f['group']} is not defined")
        if not f.get("help", "").strip():
            problems.append(f"{key}: no help text")
        if key in defaults and f["default"] != defaults[key]:
            problems.append(f"{key}: the page default differs from generic.conf")
        if f["empty"] != (key in render.MAY_BE_EMPTY):
            problems.append(f"{key}: 'empty' differs from MAY_BE_EMPTY of render.py")
        if "options" in f:
            check_options(render, f, problems)
    if shown != keys:
        problems.append("the groups do not show the keys in the order of generic.conf")


def check_options(render, f: dict, problems: list[str]) -> None:
    """A select may exist only when it offers every value build.sh accepts (R56, R57)."""
    key = f["key"]
    accepted = accepted_values(render, key)
    if accepted is None:
        problems.append(
            f"{key}: a select needs a short fixed list of values in render.py; use a text field"
        )
    elif set(f["options"]) != accepted:
        problems.append(
            f"{key}: the select offers {sorted(f['options'])}, build.sh accepts {sorted(accepted)}"
        )


ZONE_LINE = re.compile(r"\s*'([^']+)': '([^']*)',?\s*")
WHEN = re.compile(r"([A-Z0-9_]+)!?=.*")


def check_links(data: dict, problems: list[str]) -> None:
    """A field placed `after` another or shown `when` others hold a value must name keys that exist."""
    keys = [f["key"] for f in data["fields"]]
    for f in data["fields"]:
        if "after" in f and f["after"] not in keys:
            problems.append(f"{f['key']}: 'after' names {f['after']}, which the page lacks")
        for condition in f.get("when", []):
            match = WHEN.fullmatch(condition)
            if not match or match.group(1) not in keys:
                problems.append(f"{f['key']}: 'when' {condition} names no key of the page")


def check_zones(
    data: dict, defaults: dict[str, str], zoneinfo: Path | None, problems: list[str]
) -> None:
    """TIMEZONE follows ZONENAME from the page's table, so the table must hold the defaults' pair
    (the unchanged form then gives generic.conf) and equal LuCI's table plus OpenWrt's UTC."""
    zones = data.get("zones", {})
    if zones.get(defaults.get("ZONENAME")) != defaults.get("TIMEZONE"):
        problems.append("zones: the default ZONENAME does not give the default TIMEZONE")
    if zoneinfo is None:
        return
    luci = {}
    for line in zoneinfo.read_text(encoding="utf-8").splitlines():
        match = ZONE_LINE.fullmatch(line)
        if match:
            luci[match.group(1)] = match.group(2)
    if not luci:
        problems.append(f"zones: no zone read from {zoneinfo}")
    if {**luci, "UTC": "UTC"} != zones:
        diff = sorted((set(luci.items()) ^ set(zones.items())) - {("UTC", "UTC")})
        problems.append(f"zones: the page's table differs from LuCI's: {diff[:3]}")


def check_page(page: Page, problems: list[str]) -> None:
    problems.extend(page.problems)
    code = "\n".join(page.code)
    style = "\n".join(page.style)
    for found in NETWORK_JS.finditer(code):
        problems.append(f"script uses {found.group(0).strip()}, a way to call out")
    for found in STORAGE_JS.finditer(code):
        problems.append(f"script uses {found.group(0)}: R56c keeps nothing in the browser")
    for found in URL_IN_CODE.finditer(code):
        problems.append(f"script holds a URL: {found.group(0)}")
    if CSS_LOAD.search(style):
        problems.append("the style loads something (@import or url())")
    if "default-src 'none'" not in page.csp:
        problems.append("the Content-Security-Policy meta lacks default-src 'none'")
    if "connect-src" in page.csp and "connect-src 'none'" not in page.csp:
        problems.append("the Content-Security-Policy opens connect-src")


def main(argv: list[str]) -> int:
    page_path, generic_path, render_path, version_path = (Path(a) for a in argv[1:5])
    zoneinfo = Path(argv[5]) if len(argv) > 5 else None
    render = load_render(render_path)
    defaults = render.parse_profile(generic_path)
    generic = list(defaults)
    page = Page()
    text = page_path.read_text(encoding="utf-8")
    page.feed(text)
    problems: list[str] = []
    # an invisible character (a line separator in a regex, a BOM) once broke the script silently
    for number, line in enumerate(text.split("\n"), 1):
        if not line.isascii():
            problems.append(f"line {number} holds a non-ASCII character; write it as an escape")
    if page.data is None:
        print("FAIL: the page has no application/json data block")
        return 1
    data = json.loads(page.data)
    check_fields(data, generic, defaults, render, problems)
    check_zones(data, defaults, zoneinfo, problems)
    check_links(data, problems)
    for group in data["groups"]:
        if "slot" in group and group["slot"] not in page.ids:
            problems.append(
                f"group {group['id']}: the slot element {group['slot']} is not in the page"
            )
    check_page(page, problems)
    code = "\n".join(page.code)
    version = version_path.read_text(encoding="ascii").strip()
    found = re.findall(r"const LW_VERSION = '([^']*)';", code)
    if found != [version]:
        problems.append(f"LW_VERSION of the page is {found}, VERSION is {version}")
    for problem in problems:
        print(f"FAIL: {problem}")
    if problems:
        return 1
    zones = f"{len(data['zones'])} zones" + (" as in LuCI" if zoneinfo else ", LuCI's table not compared")
    print(f"{len(generic)} keys, version {version}, {zones}, no resource loaded")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
