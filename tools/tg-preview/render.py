#!/usr/bin/env python3
"""Render a chat transcript JSON as phone screens that look like Telegram for Android.

Usage: render.py TRANSCRIPT.json OUT_DIR [--title NAME]

Writes one self-contained HTML per screen (OUT_DIR/<screen>.html) and OUT_DIR/index.html that
shows them side by side. The transcript format is in tools/tg-preview/README.md. Python standard
library only.
"""

import argparse
import base64
import html
import json
import re
import sys
from dataclasses import dataclass, field
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

# Added to a page only when the transcript uses HTML, photos, forwards or a private chat, so a
# plain transcript renders byte for byte as it did before these features existed.
EXTRA_CSS = """
:root { --code: #8fd0ff; }
.tg-code, .tg-pre { font-family: "Roboto Mono", "DejaVu Sans Mono", "Liberation Mono",
  monospace; letter-spacing: 0; }
.in { --qa: var(--name); }
.private .in { --qa: var(--link); }
.out { --qa: #fff; }
.tg-code { font-size: 16.4px; color: var(--code); }
.out .tg-code { color: #fff; }
.tg-pre { display: block; position: relative; margin: 3px 0; padding: 6px 11px;
  border-radius: 6px; background: rgba(0,0,0,.24); font-size: 16px; line-height: 21px;
  white-space: pre-wrap; }
.out .tg-pre { background: rgba(0,0,0,.2); }
.tg-lang { display: block; color: var(--qa); font: 500 14.5px/20px Roboto, "Noto Sans", sans-serif;
  letter-spacing: 0; padding-bottom: 1px; }
.tg-ic { position: absolute; width: 16px; height: 16px; color: var(--qa); opacity: .9; }
.tg-pre .tg-ic { position: static; float: right; margin: 2px 0 0 8px; }
.tg-quote { position: relative; margin: 3px 0; padding: 4px 28px 4px 11px; border-radius: 6px;
  background: color-mix(in srgb, var(--qa) 15%, transparent); overflow: hidden; }
.tg-quote::before { content: ""; position: absolute; left: 0; top: 0; bottom: 0; width: 3px;
  background: var(--qa); }
.tg-quote .tg-ic { right: 6px; top: 5px; }
.tg-quote .tg-chev { right: 6px; top: auto; bottom: 5px; }
.tg-exp .q-body { display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical;
  overflow: hidden; }
.tg-spoiler { color: transparent; border-radius: 4px; text-shadow: 0 0 9px rgba(255,255,255,.7);
  background: radial-gradient(circle, rgba(255,255,255,.55) .7px, transparent 1.2px) 0 0 / 4px 4px,
    rgba(255,255,255,.1); }
.tg-spoiler * { color: transparent !important; }
.fwd { color: var(--link); font-size: 17px; line-height: 21.75px; margin-bottom: 2px; }
.fwd b { font-weight: 500; }
.photo .col { width: 293px; }
.photo .bubble { padding: 0; }
.photo .ph-hd { padding: 6px 12px 4px; }
.photo .ph-hd .quote, .photo .ph-hd .fwd { margin-bottom: 0; }
.photo .ph { border-radius: inherit; overflow: hidden; line-height: 0; }
.photo .ph-hd + .ph { border-top-left-radius: 6px; border-top-right-radius: 6px; }
.photo .ph.cap { border-bottom-left-radius: 0; border-bottom-right-radius: 0; }
.photo .ph img { display: block; width: 100%; height: auto; max-height: 420px;
  object-fit: cover; }
.photo .text.cap { padding: 6px 12px 8px; }
.photo .meta.pill { right: 8px; bottom: 8px; padding: 1px 7px; border-radius: 12px;
  background: rgba(0,0,0,.45); color: #fff; }
.private .in .col { margin-left: 8px; max-width: 343px; }
.nokb .chat { height: 774px; }
.nokb .input { top: 781px; }
.nokb .out .bubble, .nokb .out.last .bubble::before { background: linear-gradient(180deg,
  var(--out-1) 0, var(--out-2) 195px, var(--out-3) 495px, var(--out-4) 685px,
  var(--out-5) 774px) fixed; }
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


IMAGE_SIGNATURES = (
    (b"\x89PNG\r\n\x1a\n", "image/png"),
    (b"\xff\xd8\xff", "image/jpeg"),
    (b"GIF87a", "image/gif"),
    (b"GIF89a", "image/gif"),
)
MAX_PHOTO_BYTES = 10 * 1024 * 1024


class TranscriptError(Exception):
    """The transcript does not follow the format."""


def esc(text):
    return html.escape(text, quote=True)


def linkify(text, before=""):
    """Escaped HTML of text, with /commands, phone numbers and web addresses as links.

    before is the character in front of text (the end of an earlier piece of the same message),
    which the patterns need to see.
    """
    out = []
    start = len(before)
    src = before + text
    pos = start
    for found in LINK_RE.finditer(src, start):
        piece = found.group(0)
        # a full stop or bracket at the end belongs to the sentence, not to the address
        while found.lastgroup == "url" and piece[-1] in ".,;:)!?":
            piece = piece[:-1]
        out.append(esc(src[pos : found.start()]))
        out.append(f'<span class="link">{esc(piece)}</span>')
        pos = found.start() + len(piece)
    out.append(esc(src[pos:]))
    return "".join(out)


class HtmlError(Exception):
    """The text is not valid Telegram HTML; the message says where and why."""


ENTITIES = {"lt": "<", "gt": ">", "amp": "&", "quot": '"'}
INLINE_TAGS = {
    "b": "b", "strong": "b", "i": "i", "em": "i", "u": "u", "ins": "u",
    "s": "s", "strike": "s", "del": "s",
}  # fmt: skip
TOKEN_RE = re.compile(
    r"<(?P<close>/?)(?P<tag>[A-Za-z][A-Za-z0-9-]*)(?P<attrs>(?:\s[^<>]*)?)>"
    r"|(?P<lt><)|(?P<gt>>)"
    r"|&(?P<ent>#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]*);|(?P<amp>&)"
)
ATTR_RE = re.compile(
    r"""\s+([A-Za-z_][\w:.-]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'<>=`]+)))?"""
)
LANG_RE = re.compile(r"language-[\w+#.-]+")
# Telegram keeps a link only for these schemes or none (it adds http://); a digit after the
# colon is a port, as in example.org:8080
SCHEME_RE = re.compile(r"([A-Za-z][A-Za-z0-9+.-]*):(?!\d)")
LINK_SCHEMES = ("http", "https", "tg", "ton")

COPY_ICON = (
    '<svg class="tg-ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" '
    'stroke-width="2" stroke-linejoin="round"><rect x="8" y="8" width="12" height="12" '
    'rx="2.5"/><path d="M16 8V6.5A2.5 2.5 0 0 0 13.5 4h-7A2.5 2.5 0 0 0 4 6.5v7A2.5 2.5 0 0 0 '
    '6.5 16H8"/></svg>'
)
QUOTE_ICON = (
    '<svg class="tg-ic" viewBox="0 0 24 24" fill="currentColor"><path d="M6 17h3l2-4V7H5v6h3z'
    'm8 0h3l2-4V7h-6v6h3z"/></svg>'
)
CHEVRON_ICON = (
    '<svg class="tg-ic tg-chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" '
    'stroke-width="2.600" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9l6 6 6-6"/>'
    "</svg>"
)


def decode_entity(name):
    """The character of an entity name from the tag-less text (without & and ;)."""
    if name in ENTITIES:
        return ENTITIES[name]
    if name[0] == "#":
        number = int(name[2:], 16) if name[1] in "xX" else int(name[1:])
        if 0 < number <= 0x10FFFF and not 0xD800 <= number <= 0xDFFF:
            return chr(number)
    raise HtmlError(
        f"unsupported entity &{name}; (use &lt; &gt; &amp; &quot; or a number)"
    )


def decode_attr_value(value):
    """An attribute value with its entities decoded; a bare & is refused like in the text."""
    out, pos = [], 0
    for found in TOKEN_RE.finditer(value):
        if found.group("ent"):
            out.append(value[pos : found.start()] + decode_entity(found.group("ent")))
        elif found.group("amp"):
            raise HtmlError(f"a bare & in the attribute value {value!r}: write &amp;")
        else:
            raise HtmlError(f"a bare < or > in the attribute value {value!r}")
        pos = found.end()
    return "".join(out) + value[pos:]


def parse_attrs(tag, raw):
    """The attributes of a start tag as a dict; a bare attribute (expandable) has value ''."""
    attrs, pos = {}, 0
    for found in ATTR_RE.finditer(raw):
        if found.start() != pos:
            break
        name = found.group(1).lower()
        if name in attrs:
            raise HtmlError(f"<{tag}> has the attribute {name} twice")
        value = next((g for g in found.groups()[1:] if g is not None), "")
        attrs[name] = decode_attr_value(value)
        pos = found.end()
    if raw[pos:].strip():
        raise HtmlError(f"cannot read the attributes of <{tag}>: {raw[pos:].strip()!r}")
    return attrs


def check_attrs(tag, attrs):
    """Refuse every attribute Telegram does not take on this tag."""
    allowed = {
        "a": {"href"},
        "code": {"class"},
        "span": {"class"},
        "blockquote": {"expandable"},
    }
    extra = set(attrs) - allowed.get(tag, set())
    if extra:
        raise HtmlError(f"<{tag}> does not take the attribute {sorted(extra)[0]}")
    if tag == "a" and not attrs.get("href"):
        raise HtmlError('<a> needs a non-empty href="..."')
    scheme = SCHEME_RE.match(attrs["href"]) if tag == "a" else None
    if scheme and scheme.group(1).lower() not in LINK_SCHEMES:
        raise HtmlError(
            f"<a href> takes http, https, tg or ton links, not {scheme.group(1)}:"
        )
    if tag == "span" and attrs.get("class") != "tg-spoiler":
        raise HtmlError('<span> only works as <span class="tg-spoiler">')
    if tag == "code" and "class" in attrs and not LANG_RE.fullmatch(attrs["class"]):
        raise HtmlError(f'<code class="{attrs["class"]}"> is not class="language-NAME"')
    if tag == "blockquote" and attrs.get("expandable", ""):
        raise HtmlError("expandable takes no value: <blockquote expandable>")


@dataclass
class Frame:
    """An open tag and what it has collected so far."""

    tag: str
    attrs: dict
    parts: list = field(default_factory=list)
    lang: str = ""
    code_done: bool = False


class TelegramHtml:
    """Telegram's HTML subset to page markup. Anything Telegram would refuse raises HtmlError."""

    BLOCKS = ("pre", "blockquote")

    def __init__(self):
        self.stack = [Frame("", {})]
        self.before = ""
        self.swallow = False
        self.plain = []

    def feed(self, text):
        buf, pos = [], 0
        for found in TOKEN_RE.finditer(text):
            buf.append(text[pos : found.start()])
            pos = found.end()
            try:
                if found.group("ent"):
                    buf.append(decode_entity(found.group("ent")))
                    continue
                self.flush("".join(buf))
                buf = []
                self.token(found)
            except HtmlError as err:
                raise HtmlError(f"{err} (at character {found.start() + 1})") from None
        self.flush("".join(buf) + text[pos:])
        if len(self.stack) > 1:
            raise HtmlError(f"unclosed tag <{self.stack[-1].tag}>")
        return "".join(self.stack[0].parts)

    def token(self, found):
        if found.group("tag"):
            name = found.group("tag").lower()
            if found.group("close"):
                if found.group("attrs").strip():
                    raise HtmlError(f"the end tag </{name}> takes no attributes")
                self.close(name)
            else:
                self.open(name, parse_attrs(name, found.group("attrs")))
        elif found.group("lt"):
            raise HtmlError("a stray < (write &lt; for the character)")
        elif found.group("gt"):
            raise HtmlError("a stray > (write &gt; for the character)")
        else:
            raise HtmlError("a bare & (write &amp; for the character)")

    def flush(self, raw):
        """Add plain text: escaped, with auto links, except inside <code>, <pre> and <a>."""
        frame = self.stack[-1]
        # the reply preview reads the message text, which keeps the newline a block swallows
        self.plain.append(raw)
        if self.swallow and raw.startswith("\n"):
            raw = raw[1:]
        if self.swallow and raw:
            self.swallow = False
        if not raw:
            return
        if frame.tag == "pre" and frame.code_done:
            if raw.strip():
                raise HtmlError(
                    "<pre> can hold text or one <code>, not text after the <code>"
                )
            return
        in_raw = any(f.tag in ("code", "pre", "a") for f in self.stack)
        frame.parts.append(esc(raw) if in_raw else linkify(raw, self.before))
        self.before = raw[-1]

    def open(self, name, attrs):
        self.swallow = False
        if name not in INLINE_TAGS and name not in (
            "a", "code", "pre", "blockquote", "tg-spoiler", "span",
        ):  # fmt: skip
            raise HtmlError(f"unsupported tag <{name}>")
        check_attrs(name, attrs)
        parent = self.stack[-1]
        names = [f.tag for f in self.stack]
        if parent.tag == "code" or (parent.tag == "pre" and name != "code"):
            raise HtmlError(f"<{name}> cannot be inside <{parent.tag}>")
        if (
            name == "code"
            and parent.tag == "pre"
            and (parent.parts or parent.code_done)
        ):
            raise HtmlError("<code> inside <pre> must be the only content of the <pre>")
        if name in ("a", "pre", "blockquote", "code") and name in names:
            raise HtmlError(f"<{name}> cannot be inside another <{name}>")
        if name in self.BLOCKS and parent.parts and parent.parts[-1].endswith("\n"):
            parent.parts[-1] = parent.parts[-1][:-1]
        self.stack.append(Frame(name, attrs))

    def close(self, name):
        self.swallow = False
        frame = self.stack[-1]
        if len(self.stack) == 1:
            raise HtmlError(f"the end tag </{name}> has no start tag")
        if frame.tag != name:
            raise HtmlError(
                f"the end tag </{name}> does not match the open <{frame.tag}>"
            )
        self.stack.pop()
        parent = self.stack[-1]
        inner = "".join(frame.parts)
        if name == "code" and parent.tag == "pre":
            parent.parts.append(inner)
            parent.lang = frame.attrs.get("class", "")[len("language-") :]
            parent.code_done = True
        else:
            parent.parts.append(self.wrap(frame, inner))
        self.swallow = name in self.BLOCKS

    @staticmethod
    def wrap(frame, inner):
        name = frame.tag
        if name in INLINE_TAGS:
            tag = INLINE_TAGS[name]
            return f"<{tag}>{inner}</{tag}>"
        if name == "a":
            return f'<a class="link" href="{esc(frame.attrs["href"])}">{inner}</a>'
        if name == "code":
            return f'<code class="tg-code">{inner}</code>'
        if name == "pre":
            lang = (
                f'<span class="tg-lang">{esc(frame.lang)}</span>' if frame.lang else ""
            )
            return f'<pre class="tg-pre">{COPY_ICON}{lang}{inner}</pre>'
        if name == "blockquote":
            expandable = "expandable" in frame.attrs
            icons = QUOTE_ICON + (CHEVRON_ICON if expandable else "")
            cls = "tg-quote tg-exp" if expandable else "tg-quote"
            body = f'<div class="q-body">{inner}</div>'
            return f'<blockquote class="{cls}">{body}{icons}</blockquote>'
        return f'<span class="tg-spoiler">{inner}</span>'


def telegram_html(text):
    """(markup, plain text) of a Telegram HTML message; HtmlError when Telegram would refuse it."""
    parser = TelegramHtml()
    markup = parser.feed(text)
    return markup, "".join(parser.plain)


def initials(name):
    words = [w for w in re.split(r"\s+", name.strip()) if w]
    if not words:
        return "?"
    if len(words) == 1:
        return words[0][:2].upper()
    return (words[0][0] + words[1][0]).upper()


def check_message(msg, where, seen):
    """The keys every message needs; a photo may come without text (a photo with no caption)."""
    if not isinstance(msg, dict):
        raise TranscriptError(f"{where}: must be an object")
    for key in ("id", "from", "time", "text"):
        if key not in msg and not (key == "text" and "photo" in msg):
            raise TranscriptError(f"{where}: missing '{key}'")
    msg.setdefault("text", "")
    if not isinstance(msg["text"], str) or not isinstance(msg["time"], str):
        raise TranscriptError(f"{where}: 'text' and 'time' must be strings")
    if msg["from"] not in ("bot", "user"):
        raise TranscriptError(f"{where}: 'from' must be bot or user")
    if msg["id"] in seen:
        raise TranscriptError(f"{where}: duplicate id {msg['id']}")
    reply = msg.get("reply_to")
    if reply is not None and reply not in seen:
        raise TranscriptError(f"{where}: reply_to {reply} is not an earlier message")


def photo_uri(name, base, where, cache):
    """A data URI of the image file (relative to the transcript's folder, or absolute)."""
    if not isinstance(name, str) or not name:
        raise TranscriptError(f"{where}: 'photo' must be a file name")
    file = Path(name) if Path(name).is_absolute() else base / name
    if file not in cache:
        try:
            raw = file.read_bytes()
        except OSError as err:
            raise TranscriptError(
                f"{where}: cannot read the photo {name}: {err}"
            ) from err
        mime = next((m for sig, m in IMAGE_SIGNATURES if raw.startswith(sig)), None)
        if raw[:4] == b"RIFF" and raw[8:12] == b"WEBP":
            mime = "image/webp"
        if mime is None:
            raise TranscriptError(
                f"{where}: the photo {name} is not a PNG, JPEG, GIF or WebP"
            )
        if len(raw) > MAX_PHOTO_BYTES:
            raise TranscriptError(
                f"{where}: the photo {name} is over 10 MB, Telegram refuses it"
            )
        cache[file] = f"data:{mime};base64,{base64.b64encode(raw).decode()}"
    return cache[file]


def check_extras(msg, path, base, photos):
    """parse_mode, photo and forwarded_from: check them and prepare what the renderer needs."""
    where = f"{path}: message id {msg['id']}"
    forwarded = msg.get("forwarded_from")
    if forwarded is not None and (
        not isinstance(forwarded, str) or not forwarded.strip()
    ):
        raise TranscriptError(f"{where}: 'forwarded_from' must be a name")
    mode = msg.get("parse_mode")
    if mode is not None and mode != "HTML":
        raise TranscriptError(
            f"{where}: parse_mode {mode!r} is not supported, only 'HTML'"
        )
    if "photo" in msg:
        msg["_photo"] = photo_uri(msg["photo"], base, where, photos)
    if mode == "HTML":
        try:
            msg["_body"], msg["_plain"] = telegram_html(msg["text"])
        except HtmlError as err:
            raise TranscriptError(f"{where}: not valid Telegram HTML: {err}") from None


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
    data.setdefault("chat", "group")
    if data["chat"] not in ("group", "private"):
        raise TranscriptError(f"{path}: 'chat' must be group or private")
    msgs = data.get("messages")
    if not isinstance(msgs, list) or not msgs:
        raise TranscriptError(f"{path}: 'messages' must be a non-empty list")
    seen = set()
    photos = {}
    for i, msg in enumerate(msgs):
        check_message(msg, f"{path}: messages[{i}]", seen)
        check_extras(msg, path, Path(path).resolve().parent, photos)
        seen.add(msg["id"])
    # the page gets the extra style only when a feature needs it: plain pages stay unchanged
    data["_extra"] = data["chat"] == "private" or any(
        m.get("parse_mode") or m.get("photo") or m.get("forwarded_from") for m in msgs
    )
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
    first = quoted.get("_plain", quoted["text"]).split("\n", 1)[0]
    if not first.strip() and "_photo" in quoted:
        first = "Photo"
    return (
        f'<div class="quote"><div class="name">{esc(who)}</div>'
        f'<div class="qt">{esc(first)}</div></div>'
    )


def render_photo(msg, head, body, meta):
    """The inside of a photo bubble: image edge to edge, caption under it, time at its end.

    Without a caption the time sits on the image in a dark pill.
    """
    caption = msg["text"] != ""
    inner = f'<div class="ph-hd">{head}</div>' if head else ""
    inner += f'<div class="ph{" cap" if caption else ""}"><img src="{msg["_photo"]}" alt=""></div>'
    if caption:
        return (
            inner + f'<div class="text cap">{body}</div><div class="meta">{meta}</div>'
        )
    return inner + f'<div class="meta pill">{meta}</div>'


def render_message(msg, prev, nxt, by_id, data):
    out = msg["from"] == "user"
    classes = ["msg", "out" if out else "in"]
    if prev is None or prev["from"] != msg["from"]:
        classes.append("gap")
    if nxt is None or nxt["from"] != msg["from"]:
        classes.append("last")
    private = data["chat"] == "private"
    head = ""
    if not out and not private and (prev is None or prev["from"] != "bot"):
        head += f'<div class="name">{esc(data["bot_name"])}</div>'
    if msg.get("forwarded_from"):
        head += (
            f'<div class="fwd">Forwarded from <b>{esc(msg["forwarded_from"])}</b></div>'
        )
    if msg.get("reply_to") is not None:
        head += render_quote(msg, by_id, data)
    body = msg["_body"] if "_body" in msg else linkify(msg["text"])
    meta = esc(msg["time"]) + (TICK if out else "")
    if "_photo" in msg:
        inner = render_photo(msg, head, body, meta)
        classes.append("photo")
    else:
        inner = head + f'<div class="text">{body}</div><div class="meta">{meta}</div>'
    if not out and "last" in classes and not private:
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
    private = data["chat"] == "private"
    count = data["members"]
    members = (
        "last seen recently"
        if private
        else f"{count} member" + ("" if count == 1 else "s")
    )
    keys = "".join(
        '<div class="row">'
        + "".join(f'<div class="key">{esc(k)}</div>' for k in row)
        + "</div>"
        for row in data["keyboard"]
    )
    # a private chat without a reply keyboard shows just the input bar
    no_kb = private and not keys
    kb = "" if no_kb else f'<div class="kb">{keys}</div>\n'
    phone = "phone" + (" private" if private else "") + (" nokb" if no_kb else "")
    clock = upto[-1]["time"]
    title = esc(data["title"])
    return f"""<div class="{phone}">
<div class="chat">{"".join(body)}</div>
<div class="status"><span>{esc(clock)}</span>
<span class="bat">80</span></div>
<div class="top"><div class="back">{BACK}</div>
<div class="title"><div class="chat-avatar">{esc(initials(data["title"]))}</div>
<div class="t1">{title}</div><div class="t2">{members}</div></div>
<div class="menu">{MENU}</div></div>
<div class="input">{SMILE}<span class="hint">Message</span>{CLIP}<div class="cam"></div></div>
{kb}<div class="nav">{NAV}</div>
</div>"""


def page(title, body, theme, extra=False):
    css_vars = ";".join(f"--{k}:{v}" for k, v in THEMES[theme].items())
    css = CSS % {"vars": css_vars, "w": WIDTH, "h": HEIGHT}
    if extra:
        css += EXTRA_CSS
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
        body = render_screen(data, scr["last"])
        path.write_text(page(title, body, theme, data["_extra"]), encoding="utf-8")
        written.append(path)
    index = out_dir / "index.html"
    index.write_text(
        index_page(data, [s["name"] for s in data["screens"]]), encoding="utf-8"
    )
    return [*written, index]


def main(argv=None):
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
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
