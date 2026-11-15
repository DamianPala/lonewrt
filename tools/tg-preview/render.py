#!/usr/bin/env python3
"""Render a chat transcript JSON as phone screens that look like Telegram for Android.

Usage: render.py TRANSCRIPT.json OUT_DIR [--title NAME]

Writes one self-contained HTML per screen (OUT_DIR/<screen>.html) and OUT_DIR/index.html that
shows them side by side. The transcript format is in tools/tg-preview/README.md. Python standard
library only.
"""

import argparse
import html
import json
import re
import sys
from pathlib import Path

# Phone screen in CSS px; the PNG size follows from the device scale in run.sh.
WIDTH = 412
HEIGHT = 893

# Colours are variables: a light theme is one more dict in THEMES and a --theme option.
THEMES = {
    "dark": {
        "wall-top": "#0f1a21",
        "wall-mid": "#13202b",
        "wall-bottom": "#0d161d",
        "bubble-in": "#222e3a",
        "name": "#53ccc5",
        "text": "#ffffff",
        "meta-in": "#728291",
        "meta-out": "rgba(255,255,255,.75)",
        "link": "#79c4fd",
        "quote-bg": "rgba(255,255,255,.14)",
        "quote-bar": "#ffffff",
        "bar-bg": "rgba(30,42,56,.82)",
        "bar-sub": "#9aa8b6",
        "panel": "#1e2a38",
        "key": "#293646",
        "hint": "#7a8a99",
        "icon": "#8c9aa8",
        "inline-key": "rgba(38,51,64,.9)",
        "accent": "#229af0",
        "nav": "#1d2d3c",
        "nav-icon": "#e6eaee",
        "avatar-a": "#51bedf",
        "avatar-b": "#3ea7d7",
        "chat-avatar-a": "#84d06a",
        "chat-avatar-b": "#4eb344",
        "out-1": "#9445c0",
        "out-2": "#9245c0",
        "out-3": "#7d6ade",
        "out-4": "#496ddf",
        "out-5": "#3c71d7",
        "battery": "#c5c9ce",
        "battery-text": "#1b2733",
    }
}

LINK_RE = re.compile(
    r"""(?P<cmd>(?<![^\s(])/[A-Za-z][A-Za-z0-9_]*(?:@\w+)?)
      |(?P<url>(?:https?://[^\s<>]+|\b[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*
         \.(?:com|org|net|io|me|eu|rs)\b(?:/[^\s<>]*)?))
      |(?P<tel>(?<![\w.+])\+?\d{7,}(?!\w|[.,]\d)|\+\d{1,3}(?:[ -]\d{2,4}){2,4}(?!\w|[.,]\d))""",
    re.VERBOSE,
)

CSS = """
:root { %(vars)s }
* { box-sizing: border-box; margin: 0; padding: 0; }
html, body { background: #000; }
body { width: %(w)dpx; height: %(h)dpx; overflow: hidden;
  font: 18px/21.75px Roboto, "Liberation Sans", "Noto Sans", "Noto Color Emoji", sans-serif;
  color: var(--text); }
.name, .btn, .key, .t1, .avatar, .chat-avatar, .bat { font-family: Roboto, "Noto Sans",
  "Noto Color Emoji", sans-serif; font-weight: 500; }
.phone { position: relative; width: %(w)dpx; height: %(h)dpx; overflow: hidden;
  background: linear-gradient(180deg, var(--wall-top), var(--wall-mid) 60%%, var(--wall-bottom)); }
.chat { position: absolute; left: 0; right: 0; top: 0; height: 592px; overflow: hidden;
  display: flex; flex-direction: column; justify-content: flex-end; }
.msg { flex: none; position: relative; margin-top: 2px; }
.msg.gap { margin-top: 7px; }
.col { width: fit-content; max-width: 293px; margin-left: 68px; }
.out .col { max-width: 343px; margin-left: auto; margin-right: 12px; }
.bubble { position: relative; border-radius: 18px; padding: 6px 12px 8px;
  background: var(--bubble-in); overflow-wrap: anywhere; }
.out .bubble { background: linear-gradient(180deg, var(--out-1) 0, var(--out-2) 150px, var(--out-3) 380px,
    var(--out-4) 525px, var(--out-5) 600px) fixed; }
.name { color: var(--name); font-size: 17px; }
.text { white-space: pre-wrap; letter-spacing: .27px; }
.text::after { content: ""; display: inline-block; width: 46px; height: 1px; }
.out .text::after { width: 74px; }
.meta { position: absolute; right: 11px; bottom: 6px; font-size: 14px; line-height: 16px;
  color: var(--meta-in); display: flex; align-items: center; gap: 4px; }
.out .meta { color: var(--meta-out); }
.tick { width: 19px; height: 12px; }
a, .link { color: var(--link); text-decoration: none; }
.quote { position: relative; margin: 4px 0 4px; padding: 3px 8px 3px 11px; border-radius: 6px;
  background: var(--quote-bg); overflow: hidden; }
.quote::before { content: ""; position: absolute; left: 0; top: 0; bottom: 0; width: 3px;
  background: var(--quote-bar); }
.quote .name { color: #fff; }
.quote .qt { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-size: 16.3px;
  line-height: 21.75px; }
.in.last .bubble { border-bottom-left-radius: 0; }
.in.last .bubble::before { content: ""; position: absolute; left: -8px; bottom: 0;
  width: 8px; height: 8px;
  background: radial-gradient(circle at 0 0, transparent 8px, var(--bubble-in) 8.5px); }
.out.last .bubble { border-bottom-right-radius: 0; }
.out.last .bubble::before { content: ""; position: absolute; right: -8px; bottom: 0;
  width: 8px; height: 8px;
  background: linear-gradient(180deg, var(--out-1) 0, var(--out-2) 150px, var(--out-3) 380px,
    var(--out-4) 525px, var(--out-5) 600px) fixed;
  -webkit-mask: radial-gradient(circle at 100%% 0, transparent 8px, #000 8.5px);
  mask: radial-gradient(circle at 100%% 0, transparent 8px, #000 8.5px); }
.avatar { position: absolute; left: -61px; bottom: 0; width: 48px; height: 48px;
  border-radius: 50%%; background: linear-gradient(180deg, var(--avatar-a), var(--avatar-b));
  color: #fff; font-weight: 500; font-size: 17px; line-height: 48px; text-align: center; }
.ik { margin-top: 3px; display: flex; flex-direction: column; gap: 3px; }
.ik .row { display: flex; gap: 3px; }
.ik .btn { flex: 1; height: 48px; border-radius: 6px; background: var(--inline-key);
  display: flex; align-items: center; justify-content: center; text-align: center;
  padding: 0 8px; }
.ik .row:last-child .btn:first-child { border-bottom-left-radius: 14px; }
.ik .row:last-child .btn:last-child { border-bottom-right-radius: 14px; }
.status { position: absolute; left: 0; right: 0; top: 0; height: 42px; padding: 11px 19px 0;
  display: flex; justify-content: space-between; font-size: 16px; line-height: 20px;
  font-weight: 500; z-index: 5; }
.status .bat { background: var(--battery); color: var(--battery-text); border-radius: 9px;
  padding: 0 6px; font-size: 13px; font-weight: 700; height: 18px; line-height: 18px;
  margin-top: 1px; }
.top { position: absolute; top: 46px; left: 0; right: 0; height: 52px; z-index: 4; }
.top > div { position: absolute; top: 0; height: 52px; background: var(--bar-bg);
  -webkit-backdrop-filter: blur(10px); backdrop-filter: blur(10px); border-radius: 26px; }
.top .back { left: 7px; width: 52px; }
.top .menu { left: 353px; width: 52px; }
.top .title { left: 69px; width: 276px; }
.top svg { position: absolute; left: 14px; top: 14px; width: 24px; height: 24px; }
.top .chat-avatar { position: absolute; left: 2px; top: 2px; width: 48px; height: 48px;
  border-radius: 50%%; background: linear-gradient(180deg, var(--chat-avatar-a),
  var(--chat-avatar-b)); color: #fff; font-size: 18px; font-weight: 500; line-height: 48px;
  text-align: center; }
.top .t1 { position: absolute; left: 57px; top: 5px; font-size: 18.5px; line-height: 24px;
  white-space: nowrap; }
.top .t2 { position: absolute; left: 57px; top: 27px; font-size: 15.8px; line-height: 19px;
  color: var(--bar-sub); }
.input { position: absolute; left: 8px; width: 396px; top: 599px; height: 50px; z-index: 4;
  border-radius: 25px; background: var(--panel); }
.input .hint { position: absolute; left: 58px; top: 0; line-height: 50px; font-size: 20.5px;
  color: var(--hint); }
.input svg { position: absolute; }
.input .cam { position: absolute; right: 3px; top: 3px; width: 43px; height: 43px;
  border-radius: 50%%; background: var(--accent); }
.input .cam::after { content: ""; position: absolute; left: 12px; top: 12px; width: 19px;
  height: 19px; border-radius: 50%%; border: 3px solid #fff; }
.kb { position: absolute; left: 0; right: 0; top: 660px; height: 179px; z-index: 4;
  background: var(--panel); border-radius: 16px 16px 0 0; padding: 8px 9px 0;
  display: flex; flex-direction: column; gap: 5px; }
.kb .row { display: flex; gap: 5px; }
.kb .key { flex: 1; height: 50px; border-radius: 11px; background: var(--key);
  display: flex; align-items: center; justify-content: center; font-size: 17px;
  white-space: nowrap; overflow: hidden; }
.nav { position: absolute; left: 0; right: 0; top: 839px; height: 54px; background: var(--nav);
  z-index: 4; }
.nav svg { position: absolute; top: 15px; width: 24px; height: 24px; }
"""

PAGE = (
    '<!doctype html>\n<html lang="en"><head><meta charset="utf-8">'
    '<meta name="viewport" content="width=%(w)d">\n<title>%(title)s</title>\n'
    "<style>%(css)s</style></head>\n<body>\n%(body)s\n</body></html>\n"
)

TICK = (
    '<svg class="tick" viewBox="0 0 19 12" fill="none" stroke="#fff" stroke-width="1.6" '
    'stroke-linecap="round" stroke-linejoin="round"><path d="M1 6.5l3.6 3.6L11 2.5"/>'
    '<path d="M7.6 8.6l.9.9L15 2.5"/></svg>'
)
BACK = (
    '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.2" '
    'stroke-linecap="round" stroke-linejoin="round"><path d="M20 12H5M11 5l-7 7 7 7"/></svg>'
)
MENU = '<svg viewBox="0 0 24 24" fill="#fff"><circle cx="12" cy="5" r="2"/>' + (
    '<circle cx="12" cy="12" r="2"/><circle cx="12" cy="19" r="2"/></svg>'
)
SMILE = (
    '<svg style="left:14px;top:12px" width="26" height="26" viewBox="0 0 26 26" fill="none" '
    'stroke="var(--icon)" stroke-width="2"><circle cx="13" cy="13" r="10.5"/>'
    '<path d="M8.5 15.5c1 2 2.600 3 4.500 3s3.500-1 4.500-3" stroke-linecap="round"/>'
    '<circle cx="9.500" cy="10.500" r="1" fill="var(--icon)"/>'
    '<circle cx="16.500" cy="10.500" r="1" fill="var(--icon)"/></svg>'
)
CLIP = (
    '<svg style="left:312px;top:11px" width="28" height="28" viewBox="0 0 24 24" fill="none" '
    'stroke="var(--icon)" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">'
    '<path d="M20 11.500l-8 8a5 5 0 0 1-7-7l9-9a3.500 3.500 0 0 1 5 5l-9 9a2 2 0 0 1-3-3l8-8"/>'
    "</svg>"
)
NAV = (
    '<svg style="left:77px" viewBox="0 0 24 24" stroke="var(--nav-icon)" stroke-width="2.200"'
    ' stroke-linecap="round"><path d="M5 4v16M12 4v16M19 4v16"/></svg>'
    '<svg style="left:194px" viewBox="0 0 24 24" fill="none" stroke="var(--nav-icon)" '
    'stroke-width="2"><rect x="3" y="3" width="18" height="18" rx="6"/></svg>'
    '<svg style="left:308px" viewBox="0 0 24 24" fill="none" stroke="var(--nav-icon)" '
    'stroke-width="2.200" stroke-linecap="round" stroke-linejoin="round">'
    '<path d="M15 4l-8 8 8 8"/></svg>'
)


class TranscriptError(Exception):
    """The transcript does not follow the format."""


def esc(text):
    return html.escape(text, quote=True)


def linkify(text):
    """Escaped HTML of text, with /commands, phone numbers and web addresses as links."""
    out = []
    pos = 0
    for found in LINK_RE.finditer(text):
        piece = found.group(0)
        # a full stop or bracket at the end belongs to the sentence, not to the address
        while found.lastgroup == "url" and piece[-1] in ".,;:)!?":
            piece = piece[:-1]
        out.append(esc(text[pos : found.start()]))
        out.append(f'<span class="link">{esc(piece)}</span>')
        pos = found.start() + len(piece)
    out.append(esc(text[pos:]))
    return "".join(out)


def initials(name):
    words = [w for w in re.split(r"\s+", name.strip()) if w]
    if not words:
        return "?"
    if len(words) == 1:
        return words[0][:2].upper()
    return (words[0][0] + words[1][0]).upper()


def load(path):
    """Read and check a transcript; returns the dict with defaults filled in."""
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as err:
        raise TranscriptError(f"{path}: cannot read the transcript: {err}") from err
    if not isinstance(data, dict):
        raise TranscriptError(f"{path}: the top level must be an object")
    data.setdefault("title", "Chat")
    data.setdefault("members", 2)
    data.setdefault("bot_name", data["title"])
    data.setdefault("keyboard", [])
    msgs = data.get("messages")
    if not isinstance(msgs, list) or not msgs:
        raise TranscriptError(f"{path}: 'messages' must be a non-empty list")
    seen = set()
    for i, msg in enumerate(msgs):
        where = f"{path}: messages[{i}]"
        if not isinstance(msg, dict):
            raise TranscriptError(f"{where}: must be an object")
        for key in ("id", "from", "time", "text"):
            if key not in msg:
                raise TranscriptError(f"{where}: missing '{key}'")
        if not isinstance(msg["text"], str) or not isinstance(msg["time"], str):
            raise TranscriptError(f"{where}: 'text' and 'time' must be strings")
        if msg["from"] not in ("bot", "user"):
            raise TranscriptError(f"{where}: 'from' must be bot or user")
        if msg["id"] in seen:
            raise TranscriptError(f"{where}: duplicate id {msg['id']}")
        reply = msg.get("reply_to")
        if reply is not None and reply not in seen:
            raise TranscriptError(
                f"{where}: reply_to {reply} is not an earlier message"
            )
        seen.add(msg["id"])
    ids = [m["id"] for m in msgs]
    screens = data.get("screens") or [{"name": "chat", "last": ids[-1]}]
    names = set()
    for scr in screens:
        # "index" would overwrite index.html, a repeated name an earlier screen
        name = scr.get("name", "") if isinstance(scr, dict) else ""
        if (
            not re.fullmatch(r"[\w.-]+", name)
            or name in names | {"index"}
            or scr.get("last") not in ids
        ):
            raise TranscriptError(f"{path}: bad screen {scr!r}")
        names.add(name)
    data["screens"] = screens
    return data


def render_quote(msg, by_id, data):
    quoted = by_id[msg["reply_to"]]
    who = data["bot_name"] if quoted["from"] == "bot" else "You"
    first = quoted["text"].split("\n", 1)[0]
    return (
        f'<div class="quote"><div class="name">{esc(who)}</div>'
        f'<div class="qt">{esc(first)}</div></div>'
    )


def render_message(msg, prev, nxt, by_id, data):
    out = msg["from"] == "user"
    classes = ["msg", "out" if out else "in"]
    if prev is None or prev["from"] != msg["from"]:
        classes.append("gap")
    if nxt is None or nxt["from"] != msg["from"]:
        classes.append("last")
    inner = ""
    if not out and (prev is None or prev["from"] != "bot"):
        inner += f'<div class="name">{esc(data["bot_name"])}</div>'
    if msg.get("reply_to") is not None:
        inner += render_quote(msg, by_id, data)
    inner += f'<div class="text">{linkify(msg["text"])}</div>'
    meta = esc(msg["time"]) + (TICK if out else "")
    inner += f'<div class="meta">{meta}</div>'
    if not out and "last" in classes:
        inner += f'<div class="avatar">{esc(initials(data["bot_name"]))}</div>'
    kb = ""
    rows = msg.get("inline_keyboard") or []
    if rows and not out:
        kb = '<div class="ik">'
        for row in rows:
            buttons = "".join(f'<div class="btn">{esc(b)}</div>' for b in row)
            kb += f'<div class="row">{buttons}</div>'
        kb += "</div>"
    return (
        f'<div class="{" ".join(classes)}"><div class="col">'
        f'<div class="bubble">{inner}</div>{kb}</div></div>'
    )


def render_screen(data, last):
    msgs = data["messages"]
    # cut by position: ids are unique, not necessarily increasing
    upto = msgs[: [m["id"] for m in msgs].index(last) + 1]
    by_id = {m["id"]: m for m in msgs}
    body = []
    for i, msg in enumerate(upto):
        prev = upto[i - 1] if i else None
        nxt = upto[i + 1] if i + 1 < len(upto) else None
        body.append(render_message(msg, prev, nxt, by_id, data))
    count = data["members"]
    members = f"{count} member" + ("" if count == 1 else "s")
    keys = "".join(
        '<div class="row">'
        + "".join(f'<div class="key">{esc(k)}</div>' for k in row)
        + "</div>"
        for row in data["keyboard"]
    )
    clock = upto[-1]["time"]
    title = esc(data["title"])
    return f"""<div class="phone">
<div class="chat">{"".join(body)}</div>
<div class="status"><span>{esc(clock)}</span>
<span class="bat">80</span></div>
<div class="top"><div class="back">{BACK}</div>
<div class="title"><div class="chat-avatar">{esc(initials(data["title"]))}</div>
<div class="t1">{title}</div><div class="t2">{members}</div></div>
<div class="menu">{MENU}</div></div>
<div class="input">{SMILE}<span class="hint">Message</span>{CLIP}<div class="cam"></div></div>
<div class="kb">{keys}</div>
<div class="nav">{NAV}</div>
</div>"""


def page(title, body, theme):
    css_vars = ";".join(f"--{k}:{v}" for k, v in THEMES[theme].items())
    css = CSS % {"vars": css_vars, "w": WIDTH, "h": HEIGHT}
    return PAGE % {"w": WIDTH, "title": esc(title), "css": css, "body": body}


def index_page(data, names):
    cells = "".join(
        f'<figure><iframe src="{esc(n)}.html" width="{WIDTH}" height="{HEIGHT}" '
        f'scrolling="no"></iframe><figcaption>{esc(n)}</figcaption></figure>'
        for n in names
    )
    css = (
        "body{margin:0;padding:16px;background:#1a1a1a;color:#ddd;font:14px sans-serif;"
        "width:auto;height:auto;overflow:auto}"
        ".grid{display:flex;flex-wrap:nowrap;gap:16px;align-items:flex-start}"
        "figure{margin:0;flex:none}iframe{border:0;display:block}"
        "figcaption{text-align:center;padding:6px}"
    )
    return (
        f'<!doctype html>\n<html lang="en"><head><meta charset="utf-8">'
        f"<title>{esc(data['title'])}</title><style>{css}</style></head>\n"
        f'<body><div class="grid">{cells}</div></body></html>\n'
    )


def render_all(data, out_dir, theme="dark"):
    """Write the screens and the index; returns the written paths."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for scr in data["screens"]:
        path = out_dir / f"{scr['name']}.html"
        title = f"{data['title']} - {scr['name']}"
        path.write_text(
            page(title, render_screen(data, scr["last"]), theme), encoding="utf-8"
        )
        written.append(path)
    index = out_dir / "index.html"
    index.write_text(
        index_page(data, [s["name"] for s in data["screens"]]), encoding="utf-8"
    )
    return [*written, index]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("transcript", help="transcript JSON file")
    parser.add_argument("out_dir", help="directory for the HTML files")
    parser.add_argument(
        "--title", help="chat title, replaces the one in the transcript"
    )
    args = parser.parse_args(argv)
    try:
        data = load(args.transcript)
    except TranscriptError as err:
        print(f"render.py: {err}", file=sys.stderr)
        return 1
    if args.title:
        if data["bot_name"] == data["title"]:
            data["bot_name"] = args.title
        data["title"] = args.title
    for path in render_all(data, args.out_dir):
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
