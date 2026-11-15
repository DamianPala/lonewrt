# tg-preview

Screenshots of the router bot's chat as Telegram for Android (dark theme) shows it.
It runs on the laptop only; nothing here goes to a router or into the image.

Two modes, one renderer:

- **From the real code.** `scenario.sh` runs the bot inside the rootfs test harness with the fake Bot API, "taps" the keyboard buttons and prints the chat as a transcript. The texts are what the bot sent.
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

Output in the out directory: `transcript.json` (scenario only), one `<screen>.html` and `<screen>.png` per screen, `index.html` with all screens side by side.

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

`example.json` is a small mockup to start from.

## Look

Dark theme, 412 x 893 CSS px (a phone screen). Colours are CSS variables on `:root` (the `THEMES` table in `render.py`), so a light theme is one more table.
Fonts are the ones on the laptop (Liberation Sans, Noto Sans, Noto Color Emoji), not Roboto and Telegram's own emoji, so line breaks can differ by a word from a real phone.
