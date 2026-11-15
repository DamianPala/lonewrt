#!/usr/bin/env bash
# Test of tools/tg-preview without a browser: the scenario runs in the rootfs and prints a
# transcript with the expected screens and the bot's own texts; the renderer escapes text, makes
# links and refuses a broken transcript. Run: tools/tg-preview/test.sh
set -euo pipefail

FW="$(cd "$(dirname "$0")/../.." && pwd)"
HERE=$FW/tools/tg-preview
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# ---- the scenario: JSON, the ten screens, texts word for word from the bot's code
env -C "$FW" tests/rootfs/run.sh tools/tg-preview/scenario.sh >"$work/t.json" 2>"$work/t.err" ||
    { cat "$work/t.err" >&2; fail "the scenario did not run"; }

python3 -I - "$work/t.json" <<'PYEOF' || fail "the transcript is not as expected"
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
msgs = {m["id"]: m for m in data["messages"]}
texts = "\n".join(m["text"] for m in data["messages"] if m["from"] == "bot")

want = ["status", "wifi", "devices", "name-pick", "name-done", "devices-named", "balance", "sms",
        "alerts-reboot", "help"]
assert [s["name"] for s in data["screens"]] == want, data["screens"]
assert all(s["last"] in msgs for s in data["screens"])
assert data["title"] == "Home Router" and data["members"] == 2
assert [len(r) for r in data["keyboard"]] == [3, 3, 3], data["keyboard"]

users = [m for m in data["messages"] if m["from"] == "user"]
assert len(users) == 10, len(users)
# the reset note is a message of its own, the greeting (id 2) carries the keyboard, and a tap is a
# reply to the greeting, so no tap quotes "Router was reset"
note, greeting = data["messages"][0], data["messages"][1]
assert note["from"] == "bot" and note["id"] == 1 and "was reset" in note["text"]
assert greeting["from"] == "bot" and greeting["id"] == 2 and "bot is ready" in greeting["text"]
# a keyboard press is a reply to the greeting; the name is a reply to the prompt (R50)
prompt = next(m for m in data["messages"] if m["text"].startswith("\u270f\ufe0f Send the new name for"))
presses = [m for m in users if m["text"] != "Kate's iPhone"]
assert all(m["reply_to"] == greeting["id"] for m in presses), "a tap without reply_to"
reply = next(m for m in users if m["text"] == "Kate's iPhone")
assert reply["reply_to"] == prompt["id"], "the name is not a reply to the prompt"
bots = [m for m in data["messages"] if m["from"] == "bot"]
assert all(m.get("parse_mode") == "HTML" for m in bots), "a bot message without parse_mode HTML"
assert users[0]["text"] == "\U0001f7e2 Status" and users[0]["time"] == "07:58", users[0]
assert users[-1]["time"] == "08:01", users[-1]

for needle in [
    "\U0001f504 <b>Router was reset to its built-in settings.</b>\nEarlier logs and saved SMS are gone.",
    "\U0001f916 The router bot is ready. Tap a button below, or send /help",
    "\U0001f7e2 <b>Internet works</b>",
    "<blockquote>Tech: B3+B1 · RSRP -94 dBm · SINR -2.2 dB · ping 41 ms · VPN handshake 40 s ago</blockquote>",
    "Unknown device (…",
    "\u270f\ufe0f <b>Which device do you want to name?</b>",
    "\u270f\ufe0f Send the new name for <b>Unknown device (…3c:5d)</b> as a reply to this message.\n"
    "Up to 24 characters. Send <code>-</code> to remove a name.",
    "\u2705 <b>Unknown device (…3c:5d)</b> is now called <b>Kate's iPhone</b>.",
    "• Kate's iPhone · 11.0 GB",
    "\U0001f4f6 <b>Wi-Fi</b>\nName: <code>Home-Guest</code>\nPassword: <code>blue-lamp-4521</code>",
    "\U0001f4b6 <b>Balance: 0.31 EUR</b>, valid until 5 Jan\n⚠️ Top up at least 7.50 EUR",
    "<blockquote>Telekom 1466, today ",
    "= Balance 0.31 EUR, valid until 5 Jan",
    "\U0001f4e5 <b>Newest 5 of 25 SMS</b>",
    "\U0001f514 <b>Automatic messages</b>",
    "Restart cancelled.",
    "\U0001f7e2 <b>Status</b> – is the internet OK",
]:
    assert needle in texts, "missing in the bot's texts: " + needle

# the acknowledgement of /balance is edited into the answer: no message of its own is left
assert "Asked Telekom" not in texts, "the acknowledgement of /balance stayed in the chat"
balance = next(m for m in data["messages"] if m["text"].startswith("\U0001f4b6 <b>Balance:"))
assert next(s for s in data["screens"] if s["name"] == "balance")["last"] == balance["id"]
alerts = next(m for m in data["messages"] if m["text"].startswith("\U0001f514 <b>Automatic"))
assert alerts["inline_keyboard"] == [["2G backup: turn off"]], alerts
cancelled = next(m for m in data["messages"] if m["text"] == "Restart cancelled.")
assert "inline_keyboard" not in cancelled, "the cancelled question kept its buttons"
# the naming flow (R50): the button under /devices, the list as it was sent (unnamed first, short
# names two to a row, Cancel), and the confirmation after it
by_screen = {s["name"]: msgs[s["last"]] for s in data["screens"]}
assert by_screen["devices"]["inline_keyboard"] == [["\u270f\ufe0f Name a device"]], by_screen["devices"]
assert by_screen["name-pick"]["inline_keyboard"] == [
    ["Unknown device (…3c:5d)"], ["Unknown device (…b1:0f)"],
    ["Pixel-8", "Tablet-Lena"], ["work-laptop", "Cancel"]], by_screen["name-pick"]
assert by_screen["name-done"]["text"].startswith("\u2705 "), by_screen["name-done"]
assert "• Kate's iPhone · 11.0 GB" in by_screen["devices-named"]["text"]
assert "Unknown device (…3c:5d)" not in by_screen["devices-named"]["text"]
assert bots[-1]["text"].startswith("\u2753 <b>What the buttons do</b>"), "the chat does not end with help"
PYEOF
grep -q 'Router was reset to its built-in settings' "$FW/src/files/usr/lib/lw/notify.sh" ||
    fail "the reset note moved in the bot's code: update this test"

# ---- the renderer: text is escaped, commands and numbers are links, bad input is refused
cat >"$work/mini.json" <<'JSONEOF'
{"title": "Test <i>Chat</i>", "members": 2,
 "keyboard": [["A", "B"]],
 "messages": [
  {"id": 1, "from": "bot", "time": "10:00", "text": "<b>&</b> try /status or +38267000123 \"q\""},
  {"id": 2, "from": "user", "time": "10:01", "reply_to": 1, "text": "<script>x</script>"},
  {"id": 3, "from": "bot", "time": "10:02", "text": "ok 1234567.89 EUR", "inline_keyboard": [["<go>"]]}],
 "screens": [{"name": "one", "last": 3}]}
JSONEOF
python3 "$HERE/render.py" "$work/mini.json" "$work/out" >"$work/paths"
[ -s "$work/out/one.html" ] && [ -s "$work/out/index.html" ] || fail "renderer wrote no page"
page=$work/out/one.html
grep -qF '&lt;b&gt;&amp;&lt;/b&gt;' "$page" || fail "<b>& is not escaped in a bot text"
grep -qF '&lt;script&gt;x&lt;/script&gt;' "$page" || fail "a user text is not escaped"
grep -qF '&lt;go&gt;' "$page" || fail "a button label is not escaped"
grep -qF 'Test &lt;i&gt;Chat&lt;/i&gt;' "$page" || fail "the title is not escaped"
for raw in '<b>&' '<script>x' '<go>' '<i>Chat'; do
    ! grep -qF "$raw" "$page" || fail "raw '$raw' in the page"
done
grep -qF '<span class="link">/status</span>' "$page" || fail "/status is not a link"
grep -qF '<span class="link">+38267000123</span>' "$page" || fail "a phone number is not a link"
grep -qF '&quot;q&quot;' "$page" || fail "a quote is not escaped"
grep -qF 'ok 1234567.89 EUR' "$page" || fail "an amount was made a phone link"
grep -q 'src="one.html"' "$work/out/index.html" || fail "the index does not show the screen"
python3 "$HERE/render.py" "$work/mini.json" "$work/out2" --title 'Other' >/dev/null
grep -qF '<div class="t1">Other</div>' "$work/out2/one.html" || fail "--title did not apply"

# a reply to a message that does not exist, and a screen that does not exist
printf '%s' '{"messages":[{"id":1,"from":"user","time":"1:00","text":"x","reply_to":9}]}' \
    >"$work/bad.json"
! python3 "$HERE/render.py" "$work/bad.json" "$work/out3" 2>"$work/bad.err" || fail "bad reply_to accepted"
grep -q 'reply_to 9' "$work/bad.err" || fail "no clear error for a bad reply_to"
printf '%s' '{"messages":[{"id":1,"from":"bot","time":"1:00","text":"x"}],"screens":[{"name":"a","last":5}]}' \
    >"$work/bad2.json"
! python3 "$HERE/render.py" "$work/bad2.json" "$work/out4" 2>/dev/null || fail "bad screen accepted"

# the example transcript of the README renders too
python3 "$HERE/render.py" "$HERE/example.json" "$work/out5" >/dev/null || fail "example.json does not render"

# ---- a plain transcript renders byte for byte as the renderer of the first version did
old=$work/render-first.py
if git -C "$FW" show 97e3f8a:tools/tg-preview/render.py >"$old" 2>/dev/null; then
    # the scenario transcript is HTML now; without parse_mode it is a plain one again
    python3 -I - "$work/t.json" "$work/t-plain.json" <<'PYEOF'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
for m in data["messages"]:
    m.pop("parse_mode", None)
json.dump(data, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)
PYEOF
    for t in "$work/t-plain.json" "$work/mini.json" "$HERE/example.json"; do
        rm -rf "$work/cmp-old" "$work/cmp-new"
        python3 "$old" "$t" "$work/cmp-old" >/dev/null
        python3 "$HERE/render.py" "$t" "$work/cmp-new" >/dev/null
        diff -r "$work/cmp-old" "$work/cmp-new" >/dev/null || fail "plain transcript $(basename "$t") renders differently from commit 97e3f8a"
    done
else
    echo "note: commit 97e3f8a not in this clone, the no-regression comparison is skipped" >&2
fi

# ---- parse_mode HTML: Telegram's subset, drawn; anything Telegram would refuse is an error
# render_html TEXT: a transcript with one HTML bot message, id 7; the page is $work/h/chat.html
render_html() {
    rm -rf "$work/h"
    python3 -I -c '
import json, sys
msg = {"id": 7, "from": "bot", "time": "10:00", "parse_mode": "HTML", "text": sys.argv[1]}
print(json.dumps({"messages": [msg]}))' "$1" >"$work/h.json"
    python3 "$HERE/render.py" "$work/h.json" "$work/h" >/dev/null 2>"$work/h.err"
}
# the page with newlines as ~, so that a newline can be part of what is looked for
flat() { tr '\n' '~' <"$work/h/chat.html" >"$work/h/flat"; }
want_markup() { # want_markup HTML EXPECTED-MARKUP
    render_html "$1" || { cat "$work/h.err" >&2; fail "valid HTML refused: $1"; }
    flat
    grep -qF -- "${2//$'\n'/~}" "$work/h/flat" || fail "'$1' did not give '$2'"
}
want_error() { # want_error HTML TEXT-IN-THE-ERROR
    if render_html "$1"; then fail "invalid HTML accepted: $1"; fi
    grep -qF 'message id 7' "$work/h.err" || fail "the error does not name the message id: $1"
    grep -qF 'not valid Telegram HTML' "$work/h.err" || fail "no HTML error for: $1"
    grep -qF -- "$2" "$work/h.err" || fail "'$1' failed, but not with '$2': $(cat "$work/h.err")"
}
want_no() { # want_no HTML UNWANTED-MARKUP
    render_html "$1" || { cat "$work/h.err" >&2; fail "valid HTML refused: $1"; }
    flat
    ! grep -qF -- "${2//$'\n'/~}" "$work/h/flat" || fail "'$1' gave '$2'"
}

want_markup '<b>x</b>' '<b>x</b>'
want_markup '<strong>x</strong>' '<b>x</b>'
want_markup '<i>x</i>' '<i>x</i>'
want_markup '<em>x</em>' '<i>x</i>'
want_markup '<u>x</u>' '<u>x</u>'
want_markup '<ins>x</ins>' '<u>x</u>'
for tag in s strike del; do want_markup "<$tag>x</$tag>" '<s>x</s>'; done
want_markup '<code>x</code>' '<code class="tg-code">x</code>'
want_markup '<pre>a
b</pre>' '<pre class="tg-pre">'
want_markup '<pre>x</pre>' 'tg-ic'
want_markup '<pre><code class="language-python">x</code></pre>' '<span class="tg-lang">python</span>x</pre>'
want_no '<pre><code class="language-python">x</code></pre>' '<code class="tg-code">'
want_markup '<a href="https://example.org/?a=1&amp;b=2">x</a>' \
    '<a class="link" href="https://example.org/?a=1&amp;b=2">x</a>'
want_markup '<blockquote>x</blockquote>' '<blockquote class="tg-quote"><div class="q-body">x</div>'
want_markup '<blockquote expandable>x</blockquote>' '<blockquote class="tg-quote tg-exp">'
want_markup '<blockquote expandable>x</blockquote>' 'tg-chev'
want_markup '<tg-spoiler>x</tg-spoiler>' '<span class="tg-spoiler">x</span>'
want_markup '<span class="tg-spoiler">x</span>' '<span class="tg-spoiler">x</span>'
want_markup '<b>bold <i>and italic</i></b>' '<b>bold <i>and italic</i></b>'
# entities: the four named ones and numbers; a literal & is shown as &, once
want_markup '<b>&amp;</b>' '<b>&amp;</b>'
want_no '<b>&amp;</b>' '&amp;amp;'
want_markup '1 &lt; 2 &gt; 0 &quot;q&quot; &#65;&#x42;' '1 &lt; 2 &gt; 0 &quot;q&quot; AB'
# the newline next to a block is the block's own line break, not an empty line
want_no 'a
<pre>x</pre>
b' '
<pre'
want_no '<pre>x</pre>
b' '</pre>
b'

# what Telegram refuses names the message id
want_error '<script>alert(1)</script>' 'unsupported tag <script>'
want_error '<b>x' 'unclosed tag <b>'
want_error '<b><i>x</b></i>' 'does not match the open <i>'
want_error 'x</b>' 'has no start tag'
want_error '&nbsp;' 'unsupported entity &nbsp;'
want_error '&#0;' 'unsupported entity'
want_error 'AT&T' 'bare &'
want_error '1 < 2' 'stray <'
want_error '2 > 1' 'stray >'
want_error '<br>' 'unsupported tag <br>'
want_error '<a>x</a>' 'needs a non-empty href'
want_error '<a href="javascript:alert(1)">x</a>' 'not javascript:'
want_markup '<a href="tg://user?id=1">x</a> <a href="example.org:8080/a">y</a>' 'href="tg://user?id=1"'
want_error '<b onclick="x">y</b>' 'does not take the attribute onclick'
want_error '<span class="red">x</span>' 'tg-spoiler'
want_error '<code class="x">y</code>' 'language-NAME'
want_error '<pre><b>x</b></pre>' '<b> cannot be inside <pre>'
want_error '<code><b>x</b></code>' '<b> cannot be inside <code>'
want_error '<a href="x"><a href="y">z</a></a>' 'cannot be inside another <a>'
want_error '<blockquote><blockquote>x</blockquote></blockquote>' 'cannot be inside another <blockquote>'
python3 -I -c '
import json
print(json.dumps({"messages": [{"id": 7, "from": "bot", "time": "1:00", "text": "x", "parse_mode": "MarkdownV2"}]}))' \
    >"$work/pm.json"
! python3 "$HERE/render.py" "$work/pm.json" "$work/pm" 2>"$work/pm.err" || fail "parse_mode MarkdownV2 accepted"
grep -qF 'message id 7' "$work/pm.err" || fail "the parse_mode error does not name the message id"
# without parse_mode the same text stays plain and escaped
printf '%s' '{"messages":[{"id":7,"from":"bot","time":"1:00","text":"<b>x</b> &amp;"}]}' >"$work/np.json"
python3 "$HERE/render.py" "$work/np.json" "$work/np" >/dev/null
grep -qF '&lt;b&gt;x&lt;/b&gt; &amp;amp;' "$work/np/chat.html" || fail "text without parse_mode is not plain"

# auto links: in plain text pieces of both modes, never inside <code>, <pre> or <a>
want_markup '/status and +38267000123 and example.org' '<span class="link">/status</span>'
want_markup '<b>/status</b>' '<b><span class="link">/status</span></b>'
want_no 'a<b>/status</b>' '<span class="link">'
want_no '<code>/status +38267000123 example.org</code>' '<span class="link">'
want_no '<pre>/status +38267000123</pre>' '<span class="link">'
want_no '<a href="https://example.org">/status +38267000123 example.org</a>' '<span class="link">'
want_no '<a href="https://example.org">/status</a> <code>/help</code>' '<span class="link">'
render_html '/status <code>/status</code> <a href="x">/status</a> /help'
[ "$(grep -o '<span class="link">' "$work/h/chat.html" | wc -l)" = 2 ] ||
    fail "auto links: expected the two plain /commands only"
# the reply preview shows the text without tags
python3 -I -c '
import json
msgs = [
    {"id": 1, "from": "bot", "time": "1:00", "parse_mode": "HTML", "text": "<b>Wi-Fi</b> &amp; <i>more</i>\nsecond"},
    {"id": 2, "from": "user", "time": "1:01", "reply_to": 1, "text": "ok"},
]
print(json.dumps({"messages": msgs}))' >"$work/rq.json"
python3 "$HERE/render.py" "$work/rq.json" "$work/rq" >/dev/null
grep -qF '<div class="qt">Wi-Fi &amp; more</div>' "$work/rq/chat.html" || fail "the quote shows markup"
python3 -I -c '
import json
msgs = [
    {"id": 1, "from": "bot", "time": "1:00", "parse_mode": "HTML", "text": "<blockquote>q</blockquote>\nnext"},
    {"id": 2, "from": "user", "time": "1:01", "reply_to": 1, "text": "ok"},
]
print(json.dumps({"messages": msgs}))' >"$work/rq2.json"
python3 "$HERE/render.py" "$work/rq2.json" "$work/rq2" >/dev/null
grep -qF '<div class="qt">q</div>' "$work/rq2/chat.html" || fail "the quote preview lost the line break after a block"

# ---- photos
mkdir -p "$work/ph"
python3 -I -c '
import struct, sys, zlib
def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
row = b"\x00" + b"\xff\xff\xff" * 4
png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 4, 4, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(row * 4)) + chunk(b"IEND", b""))
open(sys.argv[1], "wb").write(png)' "$work/ph/p.png"
cat >"$work/ph/t.json" <<'JSONEOF'
{"messages": [
  {"id": 1, "from": "bot", "time": "10:00", "photo": "p.png", "parse_mode": "HTML", "text": "<b>Caption</b> /status"},
  {"id": 2, "from": "bot", "time": "10:01", "photo": "p.png"},
  {"id": 3, "from": "user", "time": "10:02", "reply_to": 2, "text": "nice"}]}
JSONEOF
python3 "$HERE/render.py" "$work/ph/t.json" "$work/ph/out" >/dev/null || fail "a photo transcript does not render"
grep -qF '<img src="data:image/png;base64,iVBORw0KGgo' "$work/ph/out/chat.html" || fail "the photo is not a data URI"
! grep -qF 'p.png' "$work/ph/out/chat.html" || fail "the page points to the image file"
grep -qF '<div class="text cap"><b>Caption</b> <span class="link">/status</span></div>' "$work/ph/out/chat.html" ||
    fail "the caption is not under the photo"
grep -qF '<div class="meta pill">10:01</div>' "$work/ph/out/chat.html" || fail "no time pill on a photo without caption"
grep -qF '<div class="meta">10:00</div>' "$work/ph/out/chat.html" || fail "the time is not at the caption"
grep -qF '<div class="qt">Photo</div>' "$work/ph/out/chat.html" || fail "a reply to a photo does not say Photo"
# the path may be absolute
sed "s|\"photo\": \"p.png\"|\"photo\": \"$work/ph/p.png\"|" "$work/ph/t.json" >"$work/abs.json"
python3 "$HERE/render.py" "$work/abs.json" "$work/abs-out" >/dev/null || fail "an absolute photo path is refused"
# a missing or unreadable file, a file that is no image, are errors that name the message
printf '%s' '{"messages":[{"id":5,"from":"bot","time":"1:00","photo":"nope.png"}]}' >"$work/ph/miss.json"
! python3 "$HERE/render.py" "$work/ph/miss.json" "$work/ph/o2" 2>"$work/ph/miss.err" || fail "a missing photo is accepted"
grep -qF 'message id 5' "$work/ph/miss.err" || fail "no message id for a missing photo"
grep -qF 'cannot read the photo nope.png' "$work/ph/miss.err" || fail "no clear error for a missing photo"
echo 'not an image' >"$work/ph/text.png"
printf '%s' '{"messages":[{"id":6,"from":"bot","time":"1:00","photo":"text.png"}]}' >"$work/ph/bad.json"
! python3 "$HERE/render.py" "$work/ph/bad.json" "$work/ph/o3" 2>"$work/ph/bad.err" || fail "a non-image photo is accepted"
grep -qF 'message id 6' "$work/ph/bad.err" || fail "no message id for a non-image photo"

# ---- forwarded messages and the private chat
cat >"$work/fw.json" <<'JSONEOF'
{"title": "Alex Owner", "chat": "private", "members": 2,
 "messages": [
  {"id": 1, "from": "bot", "time": "10:00", "text": "hello"},
  {"id": 2, "from": "bot", "time": "10:01", "forwarded_from": "Home <Router>", "text": "Wi-Fi"},
  {"id": 3, "from": "user", "time": "10:02", "text": "thanks"}]}
JSONEOF
python3 "$HERE/render.py" "$work/fw.json" "$work/fw-out" >/dev/null || fail "a private transcript does not render"
fw=$work/fw-out/chat.html
grep -qF '<div class="fwd">Forwarded from <b>Home &lt;Router&gt;</b></div>' "$fw" || fail "no Forwarded from header"
[ "$(grep -o 'class="fwd"' "$fw" | wc -l)" = 1 ] || fail "the header is on a message that was not forwarded"
grep -qF 'last seen recently' "$fw" || fail "no last seen in the private top bar"
! grep -qF 'member' "$fw" || fail "the private top bar shows the member count"
! grep -qF '<div class="name">' "$fw" || fail "a private chat shows sender names"
! grep -qF '<div class="avatar">' "$fw" || fail "a private chat shows avatars beside bubbles"
! grep -qF '<div class="kb">' "$fw" || fail "a private chat without keyboard draws one"
grep -qF 'class="phone private nokb"' "$fw" || fail "the private page is not marked"
# a group still shows the member count, the names and the keyboard; a private chat may have a keyboard
python3 "$HERE/render.py" "$work/mini.json" "$work/grp" >/dev/null
for want in '2 members' '<div class="name">' '<div class="kb">'; do
    grep -qF "$want" "$work/grp/one.html" || fail "a group chat lost '$want'"
done
sed 's|"chat": "private"|"chat": "private", "keyboard": [["A"]]|' "$work/fw.json" >"$work/fwk.json"
python3 "$HERE/render.py" "$work/fwk.json" "$work/fwk-out" >/dev/null
grep -qF '<div class="key">A</div>' "$work/fwk-out/chat.html" || fail "a private keyboard is not drawn"
printf '%s' '{"chat":"channel","messages":[{"id":1,"from":"bot","time":"1:00","text":"x"}]}' >"$work/ch.json"
! python3 "$HERE/render.py" "$work/ch.json" "$work/ch-out" 2>/dev/null || fail "chat 'channel' accepted"

echo "PASS tg-preview"
