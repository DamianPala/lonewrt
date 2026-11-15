# tg-preview

Screenshots of the router bot's chat as Telegram for Android (dark theme) shows it.
It runs on the laptop only; nothing here goes to a router or into the image.

Two modes, one renderer:

- **From the real code.** `scenario.sh` runs the bot inside the rootfs test harness with the fake Bot API, "taps" the keyboard buttons and prints the chat as a transcript. The texts are what the bot sent, and `parse_mode` is what the fake API recorded for each message or edit (the bot sends HTML, SPEC R37g), so the pictures show the real markup. The first message is the reset note and the second the greeting with the keyboard (R37f); a tap is a reply to the greeting. The scenario also names a device (R50): the button under `/devices`, the list (kept as it was sent, not as the tap on a device edits it afterwards), the prompt, the owner's reply to the prompt (`reply_to` is the prompt, not the greeting) and `/devices` again; screens `name-pick`, `name-done` and `devices-named`.
- **Mockup.** A hand-written transcript in the same format, for message changes that have no code yet.

```sh
tools/tg-preview/run.sh                              # scenario, render, PNG per screen
tools/tg-preview/run.sh --transcript my-chat.json    # render a hand-written transcript
tools/tg-preview/test.sh                             # scenario + renderer checks, no browser
```

`run.sh` options: `--title NAME` (chat title), `--out DIR` (default `tests/.out/tg-preview/`).
Environment: `TGP_CHROME` (browser program; default `google-chrome`, `google-chrome-stable`, `chromium`), `TGP_SCALE` (device scale, default 2.62, so 412 CSS px become 1079 px).
It needs `python3` and a Chrome or Chromium; the scenario needs `bwrap` and the rootfs like the tests (`./fetch-deps.sh`).
A snap Chromium cannot read some paths; use `google-chrome` if the PNGs stay empty.

The Wi-Fi screen is a photo (SPEC R51). The scenario's QR tools are stand-ins that draw no real code, so the transcript carries the text of the code as `photo_qr`, and `run.sh` has `photos.py` draw it with the laptop's `qrencode` (needed for the scenario; `apt install qrencode`) into `qr-<id>.png` next to the transcript, set as the message's `photo`. The picture is a PNG of the same text, where the router sends a JPEG.

Output in the out directory: `transcript.json` and `qr-<id>.png` (scenario only), one `<screen>.html` and `<screen>.png` per screen, `index.html` with all screens side by side.

## Transcript format

Plain JSON, one object:

```json
{
  "title": "Home Router",
  "members": 2,
  "bot_name": "Home Router",
  "keyboard": [["🟢 Status", "📶 Wi-Fi"], ["❓ Help"]],
  "messages": [
    {"id": 1, "from": "bot", "time": "09:00", "text": "…"},
    {"id": 2, "from": "user", "time": "09:01", "reply_to": 1, "text": "🟢 Status"},
    {"id": 3, "from": "bot", "time": "09:01", "text": "…", "inline_keyboard": [["Button"]]}
  ],
  "screens": [{"name": "status", "last": 3}]
}
```

| Key | Meaning |
|---|---|
| `title` | chat title in the top bar (`--title` replaces it) |
| `members` | member count under the title |
| `bot_name` | sender name on the bot's bubbles and in quotes; default is `title` |
| `keyboard` | the reply keyboard: rows of button labels (3 x 3 for the router bot) |
| `messages` | in chat order. `id` is unique; `from` is `bot` or `user`; `time` is `HH:MM`; `text` is plain text with `\n` for line breaks |
| `reply_to` | optional, the `id` of an earlier message; shown as the quote block (sender, first line of the text). In a group the client sends a reply-keyboard press as a reply to the message that carried the keyboard, so every `user` message of the scenario has `reply_to` of the greeting |
| `inline_keyboard` | optional, on a `bot` message: rows of button labels shown under the bubble |
| `screens` | optional list of `{"name", "last"}` (each name once, not `index`); each becomes `<name>.html` and `.png`, the chat scrolled so that message `last` sits just above the input bar and earlier messages are cut at the top. Without it there is one screen `chat` ending at the last message |

The renderer escapes all text, so `<`, `>` and `&` show literally.
Like Telegram it turns `/commands`, phone numbers (7 digits or more) and web addresses into blue links.
A bot message that was edited is written with its final text and buttons.

### Optional keys

| Key | Where | Meaning |
|---|---|---|
| `parse_mode` | message | `"HTML"`: `text` (and a photo caption) is Telegram's HTML subset, drawn like the Android app. Without it the text is plain and escaped. No other value is accepted |
| `photo` | message | path of an image (PNG, JPEG, GIF or WebP, up to 10 MB), relative to the transcript file or absolute. Drawn on top of the bubble, full width; `text` is the optional caption, the time sits at the end of the caption, or on the image in a dark pill when there is no caption. The image is embedded in each page as a data URI |
| `forwarded_from` | message | a name; the bubble starts with the "Forwarded from **name**" line in the link colour |
| `chat` | top level | `"group"` (default) or `"private"`. Private: the top bar shows "last seen recently" instead of the member count (`members` is ignored), incoming bubbles have no sender name and no avatar, and a missing or empty `keyboard` draws no reply keyboard, just the input bar. In a private chat `from: "bot"` is the other person (the owner a guest talks to), `user` is you |

### HTML text

The HTML must follow Telegram's documented rules; the renderer refuses what breaks them, with an error that names the message `id`, instead of drawing something close.
It is stricter than the Telegram server may be: the server can keep a bare `>` or `&` as text or quietly drop a link or nesting it does not take, but the docs do not promise that, so the bot should not rely on it.
Allowed: `<b> <strong> <i> <em> <u> <ins> <s> <strike> <del> <code> <pre> <a href="..."> <blockquote> <blockquote expandable> <tg-spoiler> <span class="tg-spoiler">` and `<pre><code class="language-x">` (the language shows above the code).
Entities: `&lt; &gt; &amp; &quot;` and numeric ones (`&#169;`, `&#xA9;`). A literal `<`, `>` or `&` in the text must be written as an entity, so `<b>&amp;</b>` shows a bold `&`.
Refused: any other tag or attribute (also `<tg-emoji>` and `<tg-time>`, which Telegram takes but this renderer does not draw), an unclosed, unmatched or misnested tag, an unknown entity, a bare `<`, `>` or `&` (also in an attribute value), `<a>` without `href` or with a scheme other than `http`, `https`, `tg` or `ton`, and nesting that Telegram does not take (anything inside `<code>`, anything but one `<code>` inside `<pre>`, a `<a>`, `<pre>`, `<code>` or `<blockquote>` inside the same tag).
Auto links (`/commands`, phone numbers, web addresses) apply to the plain text pieces, never inside `<code>`, `<pre>` or `<a>`.
The line break next to a `<pre>` or `<blockquote>` belongs to the block, as in Telegram, so it adds no empty line.
An expandable quote is drawn collapsed to three lines with the expand arrow; a spoiler is a static dotted block (Telegram animates it).

`example.json` is a small mockup to start from.

## Look

Dark theme, 412 x 893 CSS px (a phone screen). Colours are CSS variables on `:root` (the `THEMES` table in `render.py`), so a light theme is one more table.
Fonts are the ones on the laptop (Liberation Sans, Noto Sans, Noto Color Emoji), not Roboto and Telegram's own emoji, so line breaks can differ by a word from a real phone.
