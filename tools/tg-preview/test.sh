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

# ---- the scenario: JSON, the seven screens, texts word for word from the bot's code
env -C "$FW" tests/rootfs/run.sh tools/tg-preview/scenario.sh >"$work/t.json" 2>"$work/t.err" ||
    { cat "$work/t.err" >&2; fail "the scenario did not run"; }

python3 -I - "$work/t.json" <<'PYEOF' || fail "the transcript is not as expected"
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
msgs = {m["id"]: m for m in data["messages"]}
texts = "\n".join(m["text"] for m in data["messages"] if m["from"] == "bot")

want = ["status", "wifi", "devices", "balance", "sms", "alerts-reboot", "help"]
assert [s["name"] for s in data["screens"]] == want, data["screens"]
assert all(s["last"] in msgs for s in data["screens"])
assert data["title"] == "Home Router" and data["members"] == 2
assert [len(r) for r in data["keyboard"]] == [3, 3, 3], data["keyboard"]

users = [m for m in data["messages"] if m["from"] == "user"]
assert len(users) == 8, len(users)
first = data["messages"][0]
assert first["from"] == "bot" and first["id"] == 1
assert all(m["reply_to"] == first["id"] for m in users), "a tap without reply_to"
assert users[0]["text"] == "\U0001f7e2 Status" and users[0]["time"] == "07:58", users[0]
assert users[-1]["time"] == "08:00", users[-1]

for needle in [
    "\U0001f504 Router was reset to its built-in settings.\nEarlier logs and saved SMS are gone.",
    "\U0001f916 The router bot is ready. Tap a button below, or send /help",
    "\U0001f7e2 Internet works",
    "Tech: B3+B1 · RSRP -94 · SINR -2.2 · ping 41 ms · VPN 40 s",
    "Unknown device (…",
    "\U0001f4f6 Wi-Fi for guests",
    "\U0001f4b6 Asked Telekom for the balance (SMS to 1466).",
    "= Balance 0.31 EUR, credit valid until 5 Jan",
    "⚠️ Low balance: 0.31 EUR (today ",
    "\U0001f4e5 Newest 5 of 25 SMS",
    "\U0001f514 Automatic messages",
    "Restart cancelled.",
    "/status – is the internet OK",
]:
    assert needle in texts, "missing in the bot's texts: " + needle

alerts = next(m for m in data["messages"] if m["text"].startswith("\U0001f514 Automatic"))
assert alerts["inline_keyboard"] == [["2G backup: turn off"]], alerts
cancelled = next(m for m in data["messages"] if m["text"] == "Restart cancelled.")
assert "inline_keyboard" not in cancelled, "the cancelled question kept its buttons"
last_bot = [m for m in data["messages"] if m["from"] == "bot"][-1]
assert last_bot["text"].startswith("/status"), "the chat does not end with the help text"
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

echo "PASS tg-preview"
