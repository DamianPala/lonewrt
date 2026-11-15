#!/usr/bin/env bash
# Screenshots of the router bot's chat, as Telegram for Android shows it.
#   tools/tg-preview/run.sh                       play the scenario with the bot's real code
#   tools/tg-preview/run.sh --transcript FILE     render a hand-written transcript instead
# Options: --title NAME (chat title), --out DIR (default tests/.out/tg-preview/).
# Environment: TGP_CHROME (the browser; default google-chrome, google-chrome-stable, chromium),
# TGP_SCALE (device scale of the PNG, default 2.62: 412 CSS px become about 1080 px).
# Laptop only; nothing here touches a router or the image. See tools/tg-preview/README.md.
set -euo pipefail

FW="$(cd "$(dirname "$0")/../.." && pwd)"
HERE=$FW/tools/tg-preview
out=$FW/tests/.out/tg-preview
transcript=
title=
scale=${TGP_SCALE:-2.62}
# the phone screen in CSS px, the same numbers as WIDTH and HEIGHT in render.py
width=412
height=893

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "tg-preview: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case $1 in
        --transcript) [ $# -ge 2 ] || die "--transcript needs a file"; transcript=$2; shift 2 ;;
        --title) [ $# -ge 2 ] || die "--title needs a name"; title=$2; shift 2 ;;
        --out) [ $# -ge 2 ] || die "--out needs a directory"; out=$2; shift 2 ;;
        -h | --help) usage; exit 0 ;;
        *) die "unknown argument '$1' (try --help)" ;;
    esac
done

find_chrome() {
    local c
    if [ -n "${TGP_CHROME:-}" ]; then
        command -v "$TGP_CHROME" || die "TGP_CHROME='$TGP_CHROME' is not a program"
        return
    fi
    # the first one wins; a snap chromium cannot read some paths, so it comes last
    for c in /usr/bin/google-chrome google-chrome google-chrome-stable chromium chromium-browser; do
        if command -v "$c"; then return; fi
    done
    die "no google-chrome, google-chrome-stable or chromium on PATH (TGP_CHROME names one)"
}

command -v python3 >/dev/null || die "python3 is needed"
chrome=$(find_chrome)
mkdir -p "$out"
out=$(cd "$out" && pwd)

if [ -z "$transcript" ]; then
    command -v bwrap >/dev/null || die "bwrap is needed for the scenario (see docs/development.md)"
    transcript=$out/transcript.json
    # the scenario prints the JSON on stdout and its diagnostics on stderr
    env -C "$FW" tests/rootfs/run.sh tools/tg-preview/scenario.sh >"$transcript" ||
        die "the scenario failed (its output is above)"
else
    [ -f "$transcript" ] || die "no such transcript: $transcript"
    transcript=$(cd "$(dirname "$transcript")" && pwd)/$(basename "$transcript")
fi

args=("$transcript" "$out")
[ -z "$title" ] || args+=(--title "$title")
# not mapfile < <(...): a failing renderer must stop the run
listing=$(python3 "$HERE/render.py" "${args[@]}") || die "the renderer failed (its error is above)"
mapfile -t pages <<<"$listing"

# a throwaway profile keeps the run away from the user's browser
profile=$(mktemp -d)
trap 'rm -rf "$profile"' EXIT
for page in "${pages[@]}"; do
    case $page in */index.html) continue ;; esac
    png=${page%.html}.png
    "$chrome" --headless --no-sandbox --disable-gpu --hide-scrollbars \
        --user-data-dir="$profile" --force-device-scale-factor="$scale" \
        --window-size="$width,$height" --screenshot="$png" "file://$page" >/dev/null 2>&1 ||
        die "the browser failed on $page"
    [ -s "$png" ] || die "the browser wrote no screenshot for $page"
done

printf '%s\n' "$transcript" "${pages[@]}"
for page in "${pages[@]}"; do
    case $page in */index.html) ;; *) echo "${page%.html}.png" ;; esac
done
