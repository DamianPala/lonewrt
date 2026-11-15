#!/usr/bin/env python3
"""Draw the QR photos of a scenario transcript on the laptop (R51).

The scenario runs in the router's rootfs, where the QR tools are stand-ins that draw no real code,
so it writes the text of the code as "photo_qr" on the message the bot sent as a photo. This turns
each "photo_qr" into a PNG next to the transcript, made with the laptop's `qrencode`, and sets
"photo" to that file; render.py then embeds it. The picture differs from the router's JPEG in the
format only: the same text, margin of 4 modules.

Usage: photos.py TRANSCRIPT.json   (rewrites the file; nothing to do without a "photo_qr")
"""

import json
import subprocess
import sys
from pathlib import Path


def draw(text, out):
    """Write the QR code of text as a PNG to out; text goes in on stdin, not on a command line."""
    try:
        subprocess.run(
            ["qrencode", "-t", "PNG", "-m", "4", "-s", "8", "-o", str(out)],
            input=text.encode("utf-8"),
            check=True,
            capture_output=True,
        )
    except FileNotFoundError:
        sys.exit("photos.py: qrencode is not installed on this machine (apt install qrencode)")
    except subprocess.CalledProcessError as err:
        detail = err.stderr.decode("utf-8", "replace").strip()
        sys.exit(f"photos.py: qrencode failed: {detail}")


def convert(path):
    """Replace "photo_qr" by "photo" in every message; return how many pictures were drawn."""
    data = json.loads(path.read_text(encoding="utf-8"))
    drawn = 0
    for msg in data.get("messages", []):
        text = msg.pop("photo_qr", None)
        if text is None:
            continue
        name = f"qr-{msg['id']}.png"
        draw(text, path.parent / name)
        msg["photo"] = name
        drawn += 1
    if drawn:
        path.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    return drawn


def main(argv):
    if len(argv) != 2:
        sys.exit("usage: photos.py TRANSCRIPT.json")
    path = Path(argv[1])
    if not path.is_file():
        sys.exit(f"photos.py: no such transcript: {path}")
    convert(path)


if __name__ == "__main__":
    main(sys.argv)
