#!/usr/bin/env bash
# The page without a browser (tests/configurator/check_page.py): a field for every key of generic.conf
# and none for a key it lacks, in its order and with its defaults (R56), the empty-allowed keys of
# render.py (R57), the version of the page equal to VERSION (R56e), no resource that loads and no
# browser storage (R58, R56c). Each rule is also run against a damaged scratch copy and must fail
# naming the culprit, so the check is known to catch what it claims to catch.
# shellcheck source=tests/build/lib.bash
source "$(dirname "$0")/../build/lib.bash"
scratch cfgstatic
PAGE=$FW/configurator/index.html
GENERIC=$FW/profiles/generic.conf
check() { python3 -I "$FW/tests/configurator/check_page.py" "$@"; }
# LuCI's time zone table of the rootfs from ./fetch-deps.sh; without it the table is not compared
ZONEINFO=$LW_WORK/dl/x86/rootfs/usr/share/ucode/luci/zoneinfo.uc
zone_arg=()
[ -f "$ZONEINFO" ] && zone_arg=("$ZONEINFO")

summary=$(check "$PAGE" "$GENERIC" "$FW/src/render.py" "$FW/VERSION" "${zone_arg[@]}") || fail "the page fails: $summary"

# expect_check_fails MESSAGE PAGE GENERIC VERSION: the check fails and its output holds MESSAGE
expect_check_fails() {
    local message=$1 out
    shift
    if out=$(check "$@" 2>&1); then fail "the check passed although '$message' was expected"; fi
    grep -qF -- "$message" <<<"$out" || fail "the check output lacks '$message': $out"
}
with() { # with PAGE GENERIC VERSION MESSAGE
    expect_check_fails "$4" "$1" "$2" "$FW/src/render.py" "$3"
}

# R56 scenario: a new key in generic.conf that the page lacks fails the check naming the key
cp "$GENERIC" "$SCRATCH/generic-new.conf"
printf "NEW_KEY_Q7X9='x'\n" >>"$SCRATCH/generic-new.conf"
with "$PAGE" "$SCRATCH/generic-new.conf" "$FW/VERSION" "NEW_KEY_Q7X9"
# a key removed from generic.conf that the page still has
grep -v '^HOSTNAME=' "$GENERIC" >"$SCRATCH/generic-less.conf"
with "$PAGE" "$SCRATCH/generic-less.conf" "$FW/VERSION" "the page has the key HOSTNAME"
# a default changed in generic.conf
sed "s/^LAN_IP=.*/LAN_IP='10.9.8.7'/" "$GENERIC" >"$SCRATCH/generic-default.conf"
with "$PAGE" "$SCRATCH/generic-default.conf" "$FW/VERSION" "LAN_IP: the page default differs"
# R56e: the version of the page against VERSION
echo 9.9.9 >"$SCRATCH/VERSION"
with "$PAGE" "$GENERIC" "$SCRATCH/VERSION" "LW_VERSION"

# mutate DESCRIPTION SED-ARGS...: a damaged scratch copy of the page, which the check must refuse
refused=0
mutate() {
    local message=$1
    shift
    refused=$((refused + 1))
    sed "$@" "$PAGE" >"$SCRATCH/page.html"
    cmp -s "$PAGE" "$SCRATCH/page.html" && fail "test bug: the change for '$message' did not apply"
    with "$SCRATCH/page.html" "$GENERIC" "$FW/VERSION" "$message"
}
# R57: an empty-allowed key of render.py that the page makes required, and a select that offers
# fewer values than build.sh accepts
mutate "LAN_IP: 'empty' differs" '/"key": "LAN_IP"/s/"empty": false/"empty": true/'
mutate "LOG_LEVEL: the select offers" 's/"options": \["info", "debug"\]/"options": ["info"]/'
mutate "WIFI_COUNTRY: a select needs" '/"key": "WIFI_COUNTRY"/s/"empty": false/"empty": false, "options": ["PL"]/'
mutate "SMS_ADMINS: no help text" '/"key": "SMS_ADMINS"/,/"help"/s/"help": "[^"]*"/"help": ""/'
# R58: every way a page can load something or call out
mutate "<img> can load a resource" 's|</main>|<img src="https://x.example/a.png"></main>|'
mutate "<script src=" 's|</main>|<script src="https://x.example/a.js"></script></main>|'
mutate "<link rel=stylesheet> loads a file" 's|</head>|<link rel="stylesheet" href="https://x.example/a.css"></head>|'
mutate "the style loads something" 's|</style>|@import "https://x.example/a.css";</style>|'
mutate "script uses fetch" "s|start();\$|fetch('x');start();|"
mutate "script uses sendBeacon" "s|start();\$|navigator.sendBeacon('x');start();|"
mutate "script uses WebSocket" "s|start();\$|new WebSocket('x');start();|"
mutate "script holds a URL" "s|start();\$|const u = 'https://x.example/';start();|"
mutate "is not a plain link" 's|</main>|<a href="https://x.example/" rel="noreferrer">x</a></main>|'
mutate "the Content-Security-Policy meta lacks" "s/default-src 'none'; //"
# R56c: browser storage
mutate "script uses localStorage" "s|start();\$|localStorage.setItem('a','b');start();|"
mutate "script uses document.cookie" "s|start();\$|document.cookie='a=b';start();|"

# TIMEZONE follows ZONENAME: the default pair must be in the table, and the table must be LuCI's
mutate "zones: the default ZONENAME" 's|"Europe/Warsaw": "CET-1CEST,M3.5.0,M10.5.0/3"|"Europe/Warsaw": "CET-1"|'
mutate "TIMEZONE: 'after' names" 's|"after": "ZONENAME"|"after": "ZONE_NAME"|'
mutate "LOW_BALANCE: 'when' TG_TOKEN!= names no key" 's|"when": \["TG_BOT_TOKEN!=", |"when": ["TG_TOKEN!=", |'
if [ -f "$ZONEINFO" ]; then
    sed 's|"Europe/Podgorica": "CET-1CEST,M3.5.0,M10.5.0/3"|"Europe/Podgorica": "CET-1"|' "$PAGE" >"$SCRATCH/page.html"
    expect_check_fails "differs from LuCI's" "$SCRATCH/page.html" "$GENERIC" "$FW/src/render.py" "$FW/VERSION" "$ZONEINFO"
fi

# a non-ASCII character in the page (once a line separator in a regex broke the script unseen)
mutate "non-ASCII" "s|start();\$|const x = '$(printf '\xc3\xa9')';start();|"

# R56e, D123: the Pages workflow runs on a published release, publishes only configurator/ and pins
# every action to a full commit with its version in a comment
WF=$FW/.github/workflows/pages.yml
[ -f "$WF" ] || fail "R56e: $WF is missing"
grep -qE '^    types: \[published\]' "$WF" || fail "R56e: pages.yml does not run on a published release"
grep -q 'release.prerelease' "$WF" || fail "D123: pages.yml does not skip a pre-release"
grep -qE '^ +path: configurator$' "$WF" || fail "R56e: pages.yml does not publish only configurator/"
uses=$(grep -E '^ *(- )?uses:' "$WF" || true)
[ "$(wc -l <<<"$uses")" -ge 4 ] || fail "R56e: pages.yml has fewer than the four official actions"
bad=$(grep -vE 'uses: actions/[a-z-]+@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$' <<<"$uses" || true)
[ -z "$bad" ] || fail "pages.yml: an action is not pinned to a full commit with its version: $bad"
echo "$summary; $refused damaged copies of the page refused"
