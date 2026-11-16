#!/usr/bin/env bash
# The steps of a build run on GitHub (SPEC R53 to R54, D118): the workflow of the template repository
# only checks out a release of lonewrt and runs this script, so a fix of a step ships with the
# next release. Run it from anywhere; it works in the checkout it lives in.
#
#   ci/github-run.sh [OUT_DIR]
#
# Environment:
#   LW_PROFILE       the text of the profile (the repository secret); read once and then dropped
#                    from the environment, so no build step or test inherits it
#   LW_NAME          profile name, names the files and the profile= line of /etc/lw-build (R53j);
#                    default router
#   LW_TEST          "true" marks a test run (R54)
#   LW_REPO_PRIVATE  "true" when the user's repository is private; anything else counts as public
#   LW_VERSION       the release the workflow checked out; must be the checkout's VERSION
#   LW_OUT_DIR       where the files of the artifact go (argument 1 wins), default out/; must be
#                    empty or missing. The workflow uploads exactly this directory, and only when
#                    this script succeeded: an upload step cannot live here, so what the artifact
#                    holds is decided here and nowhere else (R53e)
#   LW_WORK          ImageBuilder and downloads, as for build.sh; locally a filled one is reused
#   GITHUB_ACTIONS, GITHUB_STEP_SUMMARY, RUNNER_TEMP   set by GitHub; without them the script
#                    runs locally: no sysctl, no apt, the summary goes to stdout
#
# Every check stops the run with one `::error::` line, before anything is written to the output
# directory. The script never prints the profile, the rendered overlay or a secret value (R53b), and
# has no `set -x`: build.sh names keys only, and the tests run on fixtures.
set -euo pipefail

FW="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$FW"

NAME=${LW_NAME:-router}
OUT_DIR=${1:-${LW_OUT_DIR:-out}}
UPSTREAM=https://github.com/DamianPala/lonewrt
# The anchor of the section "After flashing" in README.md (R55a, D122)
HINTS_ANCHOR=after-flashing
# R53g: the workflow of the template sets the same number in `retention-days`
RETENTION_DAYS=7
# build.sh's name rule (check_name); the profile name `generic` is the reference of R3
NAME_RULE='^[A-Za-z0-9][A-Za-z0-9_-]*$'
# command:apt package. R53d: a test that cannot run counts as failed, so a run installs what the
# tests and the build need instead of letting them print SKIP
HOST_TOOLS=(
    python3:python3 openssl:openssl curl:curl tar:tar zstd:zstd make:make flock:util-linux git:git
    bwrap:bubblewrap unsquashfs:squashfs-tools qrencode:qrencode zbarimg:zbar-tools
)

# The secret is taken out of the environment at once (R53b)
PROFILE_TEXT=${LW_PROFILE-}
unset LW_PROFILE

WORK=
PROFILE_FILE=
cleanup() {
    # R53c: the profile file is gone however the run ends
    if [ -n "$PROFILE_FILE" ]; then rm -f -- "$PROFILE_FILE"; fi
    if [ -n "$WORK" ]; then rm -rf -- "$WORK"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# fail MESSAGE: one annotation, no value of the profile in it
fail() {
    echo "::error::$*"
    exit 1
}

# say TEXT: a plain log line
say() {
    echo "lw-run: $*"
}

# summary_add: append stdin to the summary of the run (stdout when GitHub gives none)
summary_add() {
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        cat >>"$GITHUB_STEP_SUMMARY"
    else
        cat
    fi
}

# profile_value KEY: the value of a key of the profile file, for the checks only, never printed.
# build.sh has checked the format by then (KEY='value', no ' inside)
profile_value() {
    sed -n "s/^[[:space:]]*$1='\\(.*\\)'[[:space:]]*\$/\\1/p" "$PROFILE_FILE" | head -n 1
}

# R54, D110, D119: only a private repository builds its own profile; a test run in a public one
# builds the run fixture and ignores LW_PROFILE. Sets TEST_IN_PUBLIC=1 for that case.
TEST_IN_PUBLIC=0
check_visibility() {
    if [ "${LW_REPO_PRIVATE:-}" = true ]; then return 0; fi
    if [ "${LW_TEST:-}" != true ]; then
        fail "This repository is public, so the run stops before it builds anything. Every signed-in GitHub user can download an artifact of a public repository, and your image holds your passwords. Make the repository private (Settings > General > Danger Zone > Change visibility > Make private) and start the run again. To only try the workflow with made-up values, start it with test ticked."
    fi
    TEST_IN_PUBLIC=1
    echo "::warning::This repository is public: the image of this test run is open to every signed-in GitHub user. It is built from made-up values, not from LW_PROFILE."
    summary_add <<'EOF'
> **Warning: this repository is public, so the image of this run is open to every signed-in GitHub user.**
> It is a test run: it was built from made-up values, not from your profile. Do not flash it.

EOF
}

# R53a: the secret is there (a test run in a public repository does not read it at all)
check_secret() {
    if [ "$TEST_IN_PUBLIC" = 1 ]; then return 0; fi
    if [ -z "${PROFILE_TEXT//[[:space:]]/}" ]; then
        fail "The secret LW_PROFILE is missing or empty. Put the text of your profile into it: Settings > Secrets and variables > Actions > New repository secret, name LW_PROFILE."
    fi
}

check_name() {
    if ! [[ $NAME =~ $NAME_RULE ]]; then
        fail "The profile name must be letters, digits, - and _, starting with a letter or digit (got $(printf %q "${NAME:0:40}"))."
    fi
    if [ "$NAME" = generic ]; then
        fail "The profile name generic is taken: it is the template profile of lonewrt. Use another name, for example router."
    fi
    if [ -e "profiles/$NAME.conf" ]; then
        fail "profiles/$NAME.conf already exists here and would be overwritten; run in a fresh checkout or use another name."
    fi
    if [ -d "$OUT_DIR" ] && [ -n "$(find "$OUT_DIR" -mindepth 1 -print -quit)" ]; then
        fail "The output directory $OUT_DIR is not empty; use an empty or new one."
    fi
}

# fixture_profile FILE: the run fixture, filled by tests/build/lib.bash as the tests fill it (R54)
fixture_profile() {
    (
        # shellcheck source=tests/build/lib.bash
        source "$FW/tests/build/lib.bash"
        make_profiles "$WORK/fixture"
    )
    install -m 0600 "$WORK/fixture/fake-full.conf" "$1"
}

# write_profile: profiles/<name>.conf, readable by its owner only, LF line ends (R53c)
write_profile() {
    PROFILE_FILE=profiles/$NAME.conf
    (
        umask 077
        if [ "$TEST_IN_PUBLIC" = 1 ]; then
            fixture_profile "$PROFILE_FILE"
        else
            printf '%s\n' "$PROFILE_TEXT" | sed 's/\r$//' >"$PROFILE_FILE"
        fi
    )
    PROFILE_TEXT=
}

# check_profile: build.sh decides whether the profile is valid (R52, R53a); its message names the
# key and never the value (R3), so it goes into the annotation as it is. build.sh runs sh -n with
# the rootfs of the tests, so that is fetched first (about 10 MB)
check_profile() {
    local message
    ./fetch-deps.sh --quiet rootfs >&2
    if ! message=$(LW_IMAGE="$WORK/image" ./build.sh --render-only "$NAME" "$WORK/render/overlay" 2>&1 >/dev/null); then
        echo "$message" >&2
        fail "The profile was refused. ${message//$'\n'/ }"
    fi
    say "the profile is valid"
}

# R53i, D112: a run draws no password, so both are set in the profile and every run gives the same
check_passwords() {
    local problems=()
    if [ -z "$(profile_value WIFI_KEY)" ]; then
        problems+=("WIFI_KEY is empty.")
    fi
    if [ -z "$(profile_value ROOT_PASSWORD)" ] && [ -z "$(profile_value ROOT_PASSWORD_HASH)" ]; then
        problems+=("ROOT_PASSWORD and ROOT_PASSWORD_HASH are both empty.")
    fi
    if [ "${#problems[@]}" -gt 0 ]; then
        fail "${problems[*]} A run draws no password: set both passwords in the profile (WIFI_KEY, and ROOT_PASSWORD or ROOT_PASSWORD_HASH), so that every run gives the same ones."
    fi
}

# R53d, D105: Ubuntu 24.04 blocks the user namespaces that bwrap needs; the runner is a throwaway
# machine. If the key is missing, the tests print SKIP and stop the run by name.
lift_userns_block() {
    if [ "${GITHUB_ACTIONS:-}" != true ]; then return 0; fi
    sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 ||
        echo "::warning::Could not lift the limit on user namespaces; the tests that need bwrap will stop the run."
}

# ensure_host_tools: what the build and the tests need; installed on the runner, named locally
ensure_host_tools() {
    local pair missing=() packages=()
    for pair in "${HOST_TOOLS[@]}"; do
        if ! command -v "${pair%%:*}" >/dev/null; then
            missing+=("${pair%%:*}")
            packages+=("${pair#*:}")
        fi
    done
    if [ "${#missing[@]}" -eq 0 ]; then return 0; fi
    if [ "${GITHUB_ACTIONS:-}" != true ]; then
        fail "Missing on this machine: ${missing[*]}. Install: ${packages[*]} (README, What you need)."
    fi
    say "installing ${packages[*]}"
    sudo apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${packages[@]}"
}

# fetch_dependencies: the ImageBuilder, the third-party packages, gawk, the test rootfs and cjpeg.
# The group vm is left out: the VM bench is not part of a run (R53d).
fetch_dependencies() {
    ensure_host_tools
    ./fetch-deps.sh --quiet ib extra gawk rootfs jpeg >&2
}

# run_tests LABEL COMMAND...: print the output, then fail naming every test that failed or printed
# SKIP (R53d). The tests run on fixtures, so their output holds no value of the profile.
run_tests() {
    local label=$1 log rc=0 names
    shift
    log=$WORK/tests-$label.log
    say "tests: $*"
    "$@" 2>&1 | tee "$log" || rc=$?
    names=$(grep -E '^(FAIL|SKIP)([ :]|$)' "$log" | cut -c1-100 | paste -sd';' - | sed 's/;/; /g' || true)
    if [ -n "$names" ]; then
        fail "Tests did not pass ($label): $names."
    fi
    if [ "$rc" -ne 0 ]; then
        fail "The test runner exited with status $rc ($label); its output is in the log above."
    fi
}

# check_no_card IMAGE_DIR: with both passwords set the build draws nothing and writes no card; one
# that exists means the password rule above is wrong, so the run stops and never copies it (R53i, D113)
check_no_card() {
    if [ -e "$1/$NAME-passwords.txt" ]; then
        fail "The build wrote a password card although both passwords are set. This is a bug of the run; nothing was uploaded."
    fi
}

# publish_files IMAGE_DIR: exactly the image and the manifest (R53, R53e)
publish_files() {
    local dir=$1
    [ -f "$dir/$NAME-sysupgrade.bin" ] && [ -f "$dir/$NAME.manifest" ] ||
        fail "The build left no $NAME-sysupgrade.bin and $NAME.manifest."
    mkdir -p "$OUT_DIR"
    cp -- "$dir/$NAME-sysupgrade.bin" "$dir/$NAME.manifest" "$OUT_DIR/"
}

# R53g, R53j, R55a: version, the tag's commit, name, checksum, the day the download goes away and a
# link to the hints; never a value of the profile
write_summary() {
    local version=$1 sum expires
    sum=$(sha256sum "$OUT_DIR/$NAME-sysupgrade.bin" | cut -d' ' -f1)
    expires=$(date -u -d "+$RETENTION_DAYS days" +%Y-%m-%d)
    summary_add <<EOF
## lonewrt $version: image ready

| | |
|---|---|
| lonewrt release | $version (commit \`$(git rev-parse HEAD)\`) |
| Profile name | \`$NAME\` |
| Image | \`$NAME-sysupgrade.bin\`, sha256 \`$sum\` |
| Also in the download | \`$NAME.manifest\`, the list of packages |
| Tests | passed |
| Download until | $expires (UTC): the artifact is deleted $RETENTION_DAYS days after this run |

$(summary_next_steps "$version")
EOF
}

# summary_next_steps VERSION: the closing lines of the summary (a test run has no image to flash)
summary_next_steps() {
    if [ "$TEST_IN_PUBLIC" = 1 ]; then
        echo "A test run proves the workflow only; make the repository private and run again for your image."
        return 0
    fi
    echo "The image holds your WiFi and root passwords: keep the download private."
    echo "Flash it, then read the hints for the person who gets the router: [After flashing]($UPSTREAM/blob/v$1/README.md#$HINTS_ANCHOR)."
}

main() {
    local version
    version=$(<VERSION)
    if [ -n "${LW_VERSION:-}" ] && [ "${LW_VERSION#v}" != "$version" ]; then
        fail "The checkout holds lonewrt $version, not ${LW_VERSION}."
    fi

    check_visibility
    check_secret
    check_name
    WORK=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/lw-run.XXXXXX")
    write_profile
    check_profile
    check_passwords
    lift_userns_block
    fetch_dependencies

    say "building $NAME with lonewrt $version"
    LW_IMAGE="$WORK/image" ./build.sh "$NAME"
    check_no_card "$WORK/image"
    run_tests build tests/build/run.sh --quick
    run_tests rootfs tests/run-all.sh
    publish_files "$WORK/image"
    write_summary "$version"
    say "done: $OUT_DIR holds $NAME-sysupgrade.bin and $NAME.manifest"
}

main
