# Helpers for the tests of ci/github-run.sh (tests/ci/[0-9][0-9]-*.sh), sourced by bash.
# The script runs in a scratch copy of the repository whose build.sh, fetch-deps.sh and test runners
# are stand-ins that record their calls (tests/ci/stubs/), with a PATH of its own where `sudo` is a
# recorder, so nothing here builds an image or touches the machine. A case that needs the real
# build.sh asks for it (ci_repo real).
# shellcheck shell=bash disable=SC2034  # the variables are used by the tests that source this file
# shellcheck source=tests/build/lib.bash
source "$(dirname "${BASH_SOURCE[0]}")/../build/lib.bash"

# Keys whose values are secrets or private data of a profile (SPEC terms: secret values, R53b)
CI_SECRET_KEYS=(
    WIFI_KEY ROOT_PASSWORD ROOT_PASSWORD_HASH WWAN_PASSWORD WWAN_PIN WG_PRIVATE_KEY TG_BOT_TOKEN HC_PING_URL
    TS_AUTHKEY SMS_ADMINS
)
CI_STUBS=$FW/tests/ci/stubs

# files_in DIR: the names of the entries of DIR on one line
files_in() { find "$1" -mindepth 1 -printf '%P\n' | LC_ALL=C sort | paste -sd' ' -; }

# ci_setup NAME: scratch directory, the filled run fixture (FX), the scratch repository (REPO), the
# PATH of the runs (BIN), the folder the stand-ins record into (REC), and the output folder (CI_OUT)
ci_setup() {
    scratch "ci-$1"
    FX=$SCRATCH/fixture.conf
    make_profiles "$SCRATCH/fx"
    cp "$SCRATCH/fx/fake-full.conf" "$FX"
    REPO=$SCRATCH/repo
    REC=$SCRATCH/rec
    CI_OUT=$SCRATCH/out
    BIN=$SCRATCH/bin
    mkdir -p "$BIN" "$SCRATCH/tmp"
    # every program of the host, except a recorder for sudo: a run never reaches the real one
    ln -s /usr/bin/* /usr/local/bin/* "$BIN/" 2>/dev/null || true
    # the tools of the run exist for these tests even where the host lacks them (the script only
    # looks them up); a case that wants one missing removes it
    for tool in python3 openssl curl tar zstd make flock git bwrap unsquashfs qrencode zbarimg; do
        [ -e "$BIN/$tool" ] && continue
        printf '#!/bin/sh\nexit 0\n' >"$BIN/$tool"
        chmod +x "$BIN/$tool"
    done
    rm -f "$BIN/sudo"
    # shellcheck disable=SC2016  # $* and $STUB_REC are for the recorder to expand
    printf '#!/bin/sh\necho "sudo $*" >>"$STUB_REC/sudo"\n' >"$BIN/sudo"
    chmod +x "$BIN/sudo"
    ci_repo stub
}

# ci_repo stub|real: a fresh scratch repository with one commit; real brings the real build.sh
ci_repo() {
    rm -rf -- "$REPO"
    mkdir -p "$REPO/profiles" "$REPO/tests/build"
    cp -r "$FW/ci" "$REPO/"
    cp -r "$FW/tests/build/fixtures" "$FW/tests/build/lib.bash" "$REPO/tests/build/"
    cp "$FW/profiles/generic.conf" "$REPO/profiles/"
    cp "$FW/VERSION" "$REPO/"
    cp "$CI_STUBS/fetch-deps.sh" "$REPO/fetch-deps.sh"
    cp "$CI_STUBS/build-tests.sh" "$REPO/tests/build/run.sh"
    cp "$CI_STUBS/run-all.sh" "$REPO/tests/run-all.sh"
    if [ "$1" = real ]; then
        cp -r "$FW/build.sh" "$FW/pinned-packages.sh" "$FW/qmi-handler.sh" "$FW/src" "$FW/deps.lst" "$REPO/"
    else
        cp "$CI_STUBS/build.sh" "$REPO/build.sh"
    fi
    git -C "$REPO" init -q -b main
    git -C "$REPO" add -A
    git -C "$REPO" -c user.name=ci-test -c user.email=ci-test@example.invalid commit -q -m scratch
}

# variant FILE SED_EXPRESSION...: the run fixture with changes, written to FILE
variant() {
    local file=$1
    shift
    sed "$@" "$FX" >"$file"
}

# profile_secrets FILE: the non-empty values of the secret keys of a profile file, one per line
# (SMS_ADMINS also by number)
profile_secrets() {
    local key line value
    for key in "${CI_SECRET_KEYS[@]}"; do
        line=$(grep -E "^$key='" "$1" || true)
        value=${line#*=\'}
        value=${value%\'}
        [ -z "$value" ] || printf '%s\n' "$value"
        if [ "$key" = SMS_ADMINS ]; then tr ',' '\n' <<<"$value"; fi
    done
}

# ci_run PROFILE_FILE [VAR=value...]: the script in the scratch repository with a clean environment;
# LW_PROFILE is the file's text, the repository is private and the name is router unless the
# variables say otherwise. Sets RC, and RUN_OUT and SUMMARY (files). Checks what every run owes:
# the profile file is gone, the scratch temp dir is empty, and no secret value of PROFILE_FILE is in
# the output or the summary (R53b, R53c).
ci_run() {
    local profile=$1 text
    shift
    rm -rf -- "$REC" "$CI_OUT" "$SCRATCH/tmp" "$SCRATCH/summary.md"
    mkdir -p "$REC" "$SCRATCH/tmp"
    RUN_OUT=$SCRATCH/run.out
    SUMMARY=$SCRATCH/summary.md
    text=$(cat "$profile")
    RC=0
    (
        cd "$REPO"
        # an empty file's text is the empty secret
        env -i PATH="$BIN" HOME="$SCRATCH" TMPDIR="$SCRATCH/tmp" STUB_REC="$REC" \
            GITHUB_STEP_SUMMARY="$SUMMARY" LW_OUT_DIR="$CI_OUT" LW_REPO_PRIVATE=true LW_NAME=router \
            LW_PROFILE="$text" "$@" bash ci/github-run.sh
    ) >"$RUN_OUT" 2>&1 || RC=$?
    touch "$SUMMARY" "$REC/calls"
    [ ! -e "$REPO/profiles/router.conf" ] || fail "the profile file is still there after the run (R53c)"
    [ -z "$(files_in "$SCRATCH/tmp")" ] || fail "the run left files in its temp dir: $(files_in "$SCRATCH/tmp")"
    ci_expect_no_secrets "$profile"
}

# ci_expect_no_secrets PROFILE_FILE: no secret value of the profile in the output and the summary
ci_expect_no_secrets() {
    local value
    while IFS= read -r value; do
        [ -n "$value" ] || continue
        if grep -qF -- "$value" "$RUN_OUT" "$SUMMARY"; then
            fail "a secret value of the profile is in the output or the summary (R53b): key of '${value:0:3}...'"
        fi
    done < <(profile_secrets "$1")
}

# ci_expect_ok / ci_expect_stop PHRASE...: the run passed, or stopped with an annotation that holds
# every PHRASE, and in that case the output folder does not exist (R53e) and no summary says ready
ci_expect_ok() {
    [ "$RC" = 0 ] || fail "the run failed (status $RC): $(tail -n 5 "$RUN_OUT")"
}

ci_expect_stop() {
    local phrase
    [ "$RC" != 0 ] || fail "the run passed, expected it to stop"
    grep -q '^::error::' "$RUN_OUT" || fail "no ::error:: line: $(tail -n 5 "$RUN_OUT")"
    for phrase; do
        grep -F '::error::' "$RUN_OUT" | grep -qF -- "$phrase" || fail "the error lacks '$phrase': $(grep '::error::' "$RUN_OUT")"
    done
    [ ! -e "$CI_OUT" ] || fail "a stopped run wrote to the output folder: $(files_in "$CI_OUT")"
    ! grep -qF 'image ready' "$SUMMARY" || fail "a stopped run wrote a summary of success"
}

# ci_called PATTERN: the stand-ins were called with a line that matches (grep -E)
ci_called() { grep -qE -- "$1" "$REC/calls"; }
