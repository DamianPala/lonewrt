#!/usr/bin/env bash
# The page in a headless browser (agent-browser, bundled Chromium), opened from disk: the unchanged
# form is accepted by build.sh (R56a), the run fixture typed in comes out key by key and in order
# (R56b), a loaded profile gets "new" and "left out" (R56d), the rough checks mark and stop the text
# and the password note does not (R57, R57a), a reload and the browser's storage are empty (R56c),
# and the request log holds only the file itself (R58). Prints SKIP when there is no agent-browser.
# shellcheck source=tests/build/lib.bash
source "$(dirname "$0")/../build/lib.bash"

AB_BIN=$(command -v agent-browser || true)
[ -n "$AB_BIN" ] || AB_BIN=$HOME/.local/bin/agent-browser
if [ ! -x "$AB_BIN" ]; then
    echo "SKIP: agent-browser not found"
    exit 0
fi

scratch cfgbrowser
SESSION=lwcfg-$$
export AGENT_BROWSER_DEFAULT_TIMEOUT=20000
PAGE=${LW_CFG_PAGE:-$FW/configurator/index.html} # a scratch copy, to see the test fail
URL=file://$PAGE
trap '"$AB_BIN" --session "$SESSION" close >/dev/null 2>&1 || true; rm -rf -- "$SCRATCH"' EXIT

ab() { "$AB_BIN" --session "$SESSION" --allow-file-access "$@"; }
# js EXPRESSION: the value of a JavaScript expression in the page, as text
js() {
    local out
    out=$(ab --json eval "$1") || fail "eval failed: $1"
    jq -ej '.data.result | if type == "string" then . else tojson end' <<<"$out" || fail "eval gave no result: $1"
}
# kv FILE: the KEY<TAB>value pairs of a profile text, in order
kv() { sed -n "s/^\([A-Z][A-Z0-9_]*\)='\(.*\)'\$/\1\t\2/p" "$1"; }
out_text() { js 'document.getElementById("out").value'; }
# wait_for EXPRESSION: until it is true (a copy or a file read ends after the click returns)
wait_for() {
    local _
    for _ in $(seq 40); do
        [ "$(js "$1")" = true ] && return 0
        sleep 0.25
    done
    fail "timed out waiting for: $1"
}
# visible CSS: how many of the elements matching CSS are shown
visible() { js "[...document.querySelectorAll('$1')].filter(e => !e.hidden).length"; }
at_key() { visible "[data-key=$1] .$2"; }
expect() { [ "$2" = "$3" ] || fail "$1: expected '$3', got '$2'"; }
# fill_all FILE: type every value of a profile file into the form, as a person would, in the file's
# order, so a field shown by an earlier one (WG_ENABLED, SMS_ADMINS) is there when its turn comes; a
# field that already holds the value is left alone (TIMEZONE follows ZONENAME, and a hidden field
# holds its default)
fill_all() {
    local -a args=()
    local key value selects now
    selects=$(js 'JSON.stringify([...document.querySelectorAll("select")].map(s => s.id.slice(2)))')
    now=$(js 'JSON.stringify(Object.fromEntries([...document.querySelectorAll("[data-key]")].map(e => [e.dataset.key, document.getElementById("f-" + e.dataset.key).value])))')
    while IFS=$'\t' read -r key value; do
        case $value in *\"* | *\\*) fail "test bug: $key needs quoting for batch" ;; esac
        if [ "$(jq -r --arg k "$key" '.[$k]' <<<"$now")" = "$value" ]; then
            continue
        elif grep -q "\"$key\"" <<<"$selects"; then
            args+=("select \"#f-$key\" \"$value\"")
        else
            args+=("fill \"#f-$key\" \"$value\"")
        fi
    done < <(kv "$1")
    ab batch --bail "${args[@]}" >/dev/null || fail "typing the values failed"
}
# set_raw KEY VALUE: set a field to a value the CLI cannot type (a line break) and tell the page
set_raw() {
    local value
    value=$(jq -n --arg v "$2" '$v')
    js "(() => { const t = document.getElementById('f-$1'); t.value = $value; t.dispatchEvent(new Event('input', {bubbles: true})); return 'ok'; })()" >/dev/null
}
# a hook that records the file name of each save; a download is not a request, so it is not logged
hook_save() {
    js 'window.__saved = []; const c = HTMLAnchorElement.prototype.click; HTMLAnchorElement.prototype.click = function () { window.__saved.push(this.download); return c.call(this); }; "ok"' >/dev/null
}
# save_to FILE: press Save, keep what the browser downloaded
save_to() { ab download '#save-btn' "$1" >/dev/null || fail "Save gave no file"; }

P=$SCRATCH/profiles
make_profiles "$P"
FILLED=$P/fake-full.conf
mkdir -p "$SCRATCH/image"
render_ok() { # NAME: build.sh accepts profiles/NAME.conf
    LW_PROFILES=$P LW_IMAGE=$SCRATCH/image "$FW/build.sh" --render-only "$1" "$SCRATCH/overlay-$1" >/dev/null 2>"$SCRATCH/render.err" ||
        fail "build.sh refused $1.conf: $(tail -n 3 "$SCRATCH/render.err")"
}

# records what the Content-Security-Policy of the page blocked: in a good run nothing
echo "document.addEventListener('securitypolicyviolation', (e) => { (window.__csp = window.__csp || []).push(e.violatedDirective); });" >"$SCRATCH/csp-watch.js"
ab --init-script "$SCRATCH/csp-watch.js" open "$URL" >/dev/null || fail "the browser did not open the page"
expect "script errors on load" "$(ab --json errors | jq '.data.errors | length')" 0
expect "keys in the form" "$(js 'document.querySelectorAll("[data-key]").length')" "$(kv "$FW/profiles/generic.conf" | wc -l)"
expect "version shown" "$(js 'document.getElementById("version").textContent')" "$(cat "$FW/VERSION")"
hook_save

# R56a, R57a: the unchanged form: generic.conf's values for every key, a note and no mark at the
# empty passwords, the text made anyway, and build.sh accepts it saved as profiles/cfg.conf
expect "marks on the unchanged form" "$(visible '[data-key] .err')" 0
expect "WIFI_KEY note" "$(at_key WIFI_KEY note)" 1
expect "ROOT_PASSWORD note" "$(at_key ROOT_PASSWORD note)" 1
expect "ROOT_PASSWORD_HASH note (the note stands once, at ROOT_PASSWORD)" "$(at_key ROOT_PASSWORD_HASH note)" 0
save_to "$P/cfg.conf"
expect "saved file name" "$(js 'window.__saved.join(",")')" router.conf
diff <(kv "$FW/profiles/generic.conf") <(kv "$P/cfg.conf") >"$SCRATCH/diff" || fail "R56a: the unchanged form differs from generic.conf: $(head -n 3 "$SCRATCH/diff")"
render_ok cfg

# R56b, R57: the run fixture typed in: nothing marked, no note, the text equals the fixture
fill_all "$FILLED"
expect "marks on the fixture" "$(visible '[data-key] .err')" 0
expect "notes on the fixture" "$(visible '[data-key] .note')" 0
diff <(grep -E '^[A-Z]' "$FILLED") <(out_text) >"$SCRATCH/diff" || fail "R56b: the text differs from the fixture: $(head -n 3 "$SCRATCH/diff")"
save_to "$P/typed.conf"
render_ok typed

# R57a: an emptied WIFI_KEY or both root keys: a note, the text still made
ab fill '#f-WIFI_KEY' '' >/dev/null
expect "WIFI_KEY note after emptying" "$(at_key WIFI_KEY note)" 1
expect "no mark for an empty WIFI_KEY" "$(visible '[data-key] .err')" 0
grep -qx "WIFI_KEY=''" <(out_text) || fail "R57a: no text with an empty WIFI_KEY"
ab fill '#f-ROOT_PASSWORD_HASH' '' >/dev/null
expect "root note" "$(( $(at_key ROOT_PASSWORD note) + $(at_key ROOT_PASSWORD_HASH note) ))" 1
grep -qx "ROOT_PASSWORD_HASH=''" <(out_text) || fail "R57a: no text with both root keys empty"

# R57: an empty LAN_IP and a ' are marked at their key and give no text; a value build.sh would
# refuse for its format is not marked, because the build decides that
fill_all "$FILLED"
ab fill '#f-LAN_IP' '' >/dev/null
expect "LAN_IP mark" "$(at_key LAN_IP err)" 1
expect "text with a mark" "$(out_text)" ""
expect "Copy with a mark" "$(js 'document.getElementById("copy-btn").disabled')" true
expect "Save with a mark" "$(js 'document.getElementById("save-btn").disabled')" true
ab fill '#f-LAN_IP' '192.168.77.1' >/dev/null
expect "LAN_IP mark after the fix" "$(at_key LAN_IP err)" 0
ab fill '#f-WIFI_SSID' "Cafe'" >/dev/null
expect "quote mark" "$(at_key WIFI_SSID err)" 1
expect "text with a quote" "$(out_text)" ""
ab fill '#f-WIFI_SSID' 'Cafe' >/dev/null
set_raw SSH_KEYS $'ssh-ed25519 AAAA a ssh-ed25519 BBBB b'
expect "line break mark" "$(at_key SSH_KEYS err)" 1
expect "text with a line break" "$(out_text)" ""
# SSH_KEYS takes one key per line and gives them `;`-separated, blank lines dropped
set_raw SSH_KEYS $'ssh-ed25519 AAAA a\n\nssh-ed25519 BBBB b\n'
expect "no mark for keys on lines" "$(at_key SSH_KEYS err)" 0
grep -qx "SSH_KEYS='ssh-ed25519 AAAA a;ssh-ed25519 BBBB b'" <(out_text) || fail "SSH_KEYS lines were not joined with ;"
set_raw SSH_KEYS ''
ab fill '#f-LAN_IP' 'not an address' >/dev/null
expect "a value only build.sh refuses is not marked" "$(visible '[data-key] .err')" 0
grep -qx "LAN_IP='not an address'" <(out_text) || fail "R57: the form refused a value of the build's to judge"
# R57: the keys render.py lets be empty can be emptied without a mark, the others are marked
mapfile -t EMPTY_OK < <(python3 -I - "$FW/src/render.py" "$FW/profiles/generic.conf" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("lw_render", sys.argv[1])
render = importlib.util.module_from_spec(spec)
spec.loader.exec_module(render)
from pathlib import Path
for key in render.parse_profile(Path(sys.argv[2])):
    print(("may " if key in render.MAY_BE_EMPTY else "must ") + key)
PY
)
for entry in "${EMPTY_OK[@]}"; do
    key=${entry#* }
    [ "$(js "document.getElementById('f-$key').tagName")" = SELECT ] && continue
    [ "$(js "document.querySelector('[data-key=$key]').hidden")" = true ] && continue
    ab fill "#f-$key" '' >/dev/null
    case $entry in
        may*) expect "empty $key" "$(at_key "$key" err)" 0 ;;
        must*) expect "empty $key" "$(at_key "$key" err)" 1 ;;
    esac
done

# R56d: a profile of the previous release (no SSH_KEYS, a key since removed, CRLF, comments, a blank
# line), loaded from the text and from a file
OLD=$SCRATCH/my-old.conf
{
    printf '# saved by an older release\r\n\r\n'
    grep -E '^[A-Z]' "$FILLED" | grep -v '^SSH_KEYS=' | sed 's/$/\r/'
    printf "OLD_REMOVED_KEY_Q7X9='gone'\r\n"
} >"$OLD"
EXPECTED=$SCRATCH/expected-old.conf
sed "s/^SSH_KEYS=.*/SSH_KEYS=''/" "$FILLED" >"$EXPECTED"
ab click '#reset-btn' >/dev/null
js "document.getElementById('load-text').value = $(jq -Rs . <"$OLD"); 'ok'" >/dev/null
ab click '#load-btn' >/dev/null
diff <(grep -E '^[A-Z]' "$EXPECTED") <(out_text) >"$SCRATCH/diff" || fail "R56d: loaded values differ: $(head -n 3 "$SCRATCH/diff")"
expect "new marks" "$(visible '[data-key] .new')" 1
expect "SSH_KEYS new" "$(at_key SSH_KEYS new)" 1
report=$(js 'document.getElementById("load-report").textContent')
grep -q 'OLD_REMOVED_KEY_Q7X9' <<<"$report" || fail "R56d: the removed key is not named: $report"
grep -qi 'left out' <<<"$report" || fail "R56d: no 'left out' in the report: $report"
! grep -q 'gone' <<<"$report" || fail "R56d: the report shows a value"
ab click '#reset-btn' >/dev/null
ab upload '#load-file' "$OLD" >/dev/null
wait_for 'document.getElementById("load-report").textContent !== ""'
diff <(grep -E '^[A-Z]' "$EXPECTED") <(out_text) >"$SCRATCH/diff" || fail "R56d: the opened file differs: $(head -n 3 "$SCRATCH/diff")"
expect "name from the file" "$(js 'document.getElementById("name").value')" my-old
# text that is no profile at all changes nothing
ab click '#reset-btn' >/dev/null
js "document.getElementById('load-text').value = 'hello'; 'ok'" >/dev/null
ab click '#load-btn' >/dev/null
expect "nothing loaded" "$(js 'document.getElementById("f-HOSTNAME").value')" lte-router
grep -q 'Nothing loaded' <(js 'document.getElementById("load-report").textContent') || fail "R56d: no report for a text without keys"

# A field with `when` appears with its condition and stays while it holds a value of its own; the
# two root keys hide each other
ab click '#reset-btn' >/dev/null
for key in WG_PRIVATE_KEY WG_KEEPALIVE WWAN_AUTH WWAN_PASSWORD LOW_BALANCE SMS_REBOOT_MAX_AGE_MIN ROUTER_NAME; do
    expect "$key hidden on the defaults" "$(visible "[data-key=$key]")" 0
done
ab select '#f-WG_ENABLED' 1 >/dev/null
expect "WG keys after WG_ENABLED=1" "$(visible '[data-key^=WG_]')" 8
ab fill '#f-WG_KEEPALIVE' 25 >/dev/null
ab select '#f-WG_ENABLED' 0 >/dev/null
expect "WG keys after WG_ENABLED=0" "$(visible '[data-key^=WG_]')" 2
ab fill '#f-WWAN_APN' internet >/dev/null
expect "APN login after an APN" "$(visible '[data-key^=WWAN_]')" 4
ab fill '#f-TG_BOT_TOKEN' 1:x >/dev/null
expect "LOW_BALANCE with the token only" "$(visible '[data-key=LOW_BALANCE]')" 0
ab fill '#f-TG_CHAT_ID' 5 >/dev/null
expect "LOW_BALANCE with token and chat" "$(visible '[data-key=LOW_BALANCE]')" 1
ab fill '#f-SMS_ADMINS' +48500000001 >/dev/null
expect "SMS keys after SMS_ADMINS" "$(visible '[data-key^=SMS_],[data-key=ROUTER_NAME]')" 4
ab fill '#f-ROOT_PASSWORD' 'fake-pass-q7x9' >/dev/null
expect "hash hidden after a password" "$(visible '[data-key=ROOT_PASSWORD_HASH]')" 0
ab fill '#f-ROOT_PASSWORD' '' >/dev/null
ab fill '#f-ROOT_PASSWORD_HASH' 'x' >/dev/null
expect "password hidden after a hash" "$(visible '[data-key=ROOT_PASSWORD]')" 0
load_lines() { # load_lines TEXT: load the text into the form
    js "document.getElementById('load-text').value = $(jq -Rs . <<<"$1"); 'ok'" >/dev/null
    ab click '#load-btn' >/dev/null
}
load_lines "ROOT_PASSWORD='fake-pass-q7x9'"$'\n'"ROOT_PASSWORD_HASH='x'"
expect "both root keys shown when both set" "$(visible '[data-key^=ROOT_PASSWORD]')" 2
expect "both root keys noted" "$(( $(at_key ROOT_PASSWORD note) + $(at_key ROOT_PASSWORD_HASH note) ))" 2

# TIMEZONE follows ZONENAME and stays hidden while it holds the listed string; a loaded profile whose
# TIMEZONE differs, or whose ZONENAME is not listed, shows it with a note and keeps the loaded values
ab click '#reset-btn' >/dev/null
expect "TIMEZONE hidden on the defaults" "$(visible '[data-key=TIMEZONE]')" 0
ab select '#f-ZONENAME' 'America/New_York' >/dev/null
grep -qx "TIMEZONE='EST5EDT,M3.2.0,M11.1.0'" <(out_text) || fail "TIMEZONE did not follow ZONENAME"
expect "TIMEZONE hidden after a listed zone" "$(visible '[data-key=TIMEZONE]')" 0
load_lines "TIMEZONE='UTC0'"$'\n'"ZONENAME='Europe/Warsaw'"
expect "TIMEZONE shown when it differs" "$(visible '[data-key=TIMEZONE]')" 1
expect "TIMEZONE note when it differs" "$(at_key TIMEZONE note)" 1
grep -qx "TIMEZONE='UTC0'" <(out_text) || fail "a loaded TIMEZONE was replaced"
load_lines "TIMEZONE='XYZ-3'"$'\n'"ZONENAME='Mars/Olympus'"
expect "TIMEZONE shown for an unlisted zone" "$(visible '[data-key=TIMEZONE]')" 1
expect "unlisted zone kept" "$(js 'document.getElementById("f-ZONENAME").value')" Mars/Olympus
grep -qx "ZONENAME='Mars/Olympus'" <(out_text) || fail "an unlisted ZONENAME was not kept"
ab select '#f-ZONENAME' 'Europe/Podgorica' >/dev/null
expect "TIMEZONE hidden after picking a zone" "$(visible '[data-key=TIMEZONE]')" 0
grep -qx "TIMEZONE='CET-1CEST,M3.5.0,M10.5.0/3'" <(out_text) || fail "TIMEZONE did not follow the picked zone"
# R3c: an empty TIMEZONE is filled by the build from a listed zone, so it stays hidden; with an
# unlisted zone the build cannot fill it, so it is shown with a note
load_lines "TIMEZONE=''"$'\n'"ZONENAME='Europe/Warsaw'"
expect "empty TIMEZONE hidden for a listed zone" "$(visible '[data-key=TIMEZONE]')" 0
grep -qx "TIMEZONE=''" <(out_text) || fail "a loaded empty TIMEZONE was changed"
load_lines "TIMEZONE=''"$'\n'"ZONENAME='Mars/Olympus'"
expect "empty TIMEZONE shown for an unlisted zone" "$(visible '[data-key=TIMEZONE]')" 1
expect "empty TIMEZONE note for an unlisted zone" "$(at_key TIMEZONE note)" 1

# Copy: the text lands on the clipboard (pasted into the load box, since a page may not read it back)
ab click '#reset-btn' >/dev/null
fill_all "$FILLED"
ab click '#copy-btn' >/dev/null
wait_for 'document.getElementById("copy-status").textContent !== ""'
expect "Copy status" "$(js 'document.getElementById("copy-status").textContent')" "Copied. Paste it into the secret LW_PROFILE."
ab focus '#load-text' >/dev/null
ab clipboard paste >/dev/null
diff <(grep -E '^[A-Z]' "$FILLED") <(js 'document.getElementById("load-text").value') >"$SCRATCH/diff" ||
    fail "R56b: the copied text differs from the fixture: $(head -n 3 "$SCRATCH/diff")"

# Light and dark, and no sideways scroll on a phone
light=$(js 'getComputedStyle(document.body).backgroundColor')
ab set media dark >/dev/null
dark=$(js 'getComputedStyle(document.body).backgroundColor')
[ "$light" != "$dark" ] || fail "no dark colours: $light"
ab set media light >/dev/null
ab set viewport 375 800 >/dev/null
expect "no sideways scroll" "$(js 'document.documentElement.scrollWidth <= document.documentElement.clientWidth')" true
ab set viewport 1280 800 >/dev/null

expect "policy violations" "$(js 'JSON.stringify(window.__csp || [])')" "[]"

# R56c: a reload shows generic.conf again; nothing in the browser's storage
ab fill '#f-HOSTNAME' changed >/dev/null
ab reload >/dev/null
diff <(kv "$FW/profiles/generic.conf") <(out_text | sed -n "s/^\\([A-Z][A-Z0-9_]*\\)='\\(.*\\)'\$/\\1\\t\\2/p") >"$SCRATCH/diff" ||
    fail "R56c: a reload did not bring back generic.conf: $(head -n 3 "$SCRATCH/diff")"
expect "load box after reload" "$(js 'document.getElementById("load-text").value')" ""
expect "localStorage" "$(js 'localStorage.length')" 0
expect "sessionStorage" "$(js 'sessionStorage.length')" 0
expect "cookies" "$(js 'document.cookie')" ""
expect "IndexedDB" "$(js '(async () => "n" + (indexedDB.databases ? (await indexedDB.databases()).length : 0))()')" n0

# R58: the request log of the whole session (open, fill, load, copy, save, reload) is the file itself
log=$(ab network requests)
echo "$log" >"$SCRATCH/requests.log"
[ -n "$log" ] || fail "R58: the request log is empty, so it proves nothing"
other=$(grep -vF " $URL (Document)" <<<"$log" || true)
[ -z "$other" ] || fail "R58: the page made a request besides the file itself: $other"
expect "resources the page loaded" "$(js 'performance.getEntriesByType("resource").length')" 0

echo "$(grep -c . <<<"$log") requests, all the file itself; $(kv "$FILLED" | wc -l) keys typed"
