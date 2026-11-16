#!/usr/bin/env bash
# SPEC R53, R53b, R53c, R53e, R53g, R53j, R55a, D113: what a good run leaves: exactly the image and
# the manifest in the output folder, a summary with the version, the tag's commit, the name, the
# checksum, the day the download goes away and the link to the hints; no card; no secret value of
# the profile anywhere the script printed.
# shellcheck source=tests/ci/lib.bash
source "$(dirname "$0")/lib.bash"
ci_setup output
version=$(cat "$FW/VERSION")

ci_run "$FX" LW_VERSION="$version"
ci_expect_ok
[ "$(files_in "$CI_OUT")" = 'router-sysupgrade.bin router.manifest' ] ||
    fail "R53e: the output folder holds: $(files_in "$CI_OUT")"
cmp -s "$CI_OUT/router-sysupgrade.bin" <(echo "fake image of router") || fail "the image is not the build's"

# the summary: version, the commit of the checkout, name, checksum, the day of deletion, the hints
sum=$(sha256sum "$CI_OUT/router-sysupgrade.bin" | cut -d' ' -f1)
commit=$(git -C "$REPO" rev-parse HEAD)
expires=$(date -u -d '+7 days' +%Y-%m-%d)
for want in "$version" "$commit" "\`router\`" "$sum" "$expires" \
    "https://github.com/DamianPala/lonewrt/blob/v$version/README.md#after-flashing"; do
    grep -qF -- "$want" "$SUMMARY" || fail "R53g, R53j, R55a: the summary lacks '$want': $(cat "$SUMMARY")"
done
! grep -q 'open to every signed-in' "$SUMMARY" || fail "R54: a private run's summary has the warning"

# R55a: the link goes to a section that README.md has (GitHub's anchor of "## After flashing")
grep -qx '## After flashing' "$FW/README.md" || fail "R55a: README.md has no section 'After flashing' to link to"

# D113, R53i: a card the build wrote anyway stops the run, and is not copied
ci_run "$FX" STUB_WRITE_CARD=1
ci_expect_stop "password card"

# R53e: an output folder with files in it is refused (a stale file would be uploaded), the argument
# wins over LW_OUT_DIR, and without a summary file the summary goes to stdout
mkdir -p "$CI_OUT"
echo stale >"$CI_OUT/old.bin"
RC=0
(cd "$REPO" && env -i PATH="$BIN" HOME="$SCRATCH" TMPDIR="$SCRATCH/tmp" STUB_REC="$REC" LW_REPO_PRIVATE=true \
    LW_PROFILE="$(cat "$FX")" LW_OUT_DIR="$CI_OUT" bash ci/github-run.sh) >"$SCRATCH/stale.out" 2>&1 || RC=$?
[ "$RC" != 0 ] || fail "R53e: a run accepted an output folder with a stale file"
[ "$(files_in "$CI_OUT")" = old.bin ] || fail "R53e: the stale folder was changed"
rm -r "$CI_OUT"
mkdir -p "$REC"
RC=0
(cd "$REPO" && env -i PATH="$BIN" HOME="$SCRATCH" TMPDIR="$SCRATCH/tmp" STUB_REC="$REC" LW_REPO_PRIVATE=true \
    LW_PROFILE="$(cat "$FX")" LW_OUT_DIR="$SCRATCH/not-used" bash ci/github-run.sh "$SCRATCH/arg-out") \
    >"$SCRATCH/stdout.out" 2>&1 || RC=$?
[ "$RC" = 0 ] || fail "a run with an output folder argument failed: $(tail -n 5 "$SCRATCH/stdout.out")"
[ -f "$SCRATCH/arg-out/router.manifest" ] && [ ! -e "$SCRATCH/not-used" ] || fail "the argument did not win over LW_OUT_DIR"
grep -qF "Download until" "$SCRATCH/stdout.out" || fail "without GITHUB_STEP_SUMMARY the summary is not on stdout"

# R53b: every run of the cases above already checked its output and summary (ci_run); here the runs
# that end in different places, each with the values of the whole fixture
cases=(
    "STUB_BUILD_TESTS=fail" "STUB_ROOTFS_TESTS=skip" "STUB_WRITE_CARD=1" "LW_REPO_PRIVATE=false LW_TEST=true"
    "GITHUB_ACTIONS=true" "LW_NAME=generic"
)
for c in "${cases[@]}"; do
    # shellcheck disable=SC2086  # the case is a list of VAR=value words
    ci_run "$FX" $c
    ci_expect_no_secrets "$FX"
done
n=$(profile_secrets "$FX" | wc -l)
[ "$n" -ge 8 ] || fail "R53b: the leak check had only $n values to look for"
echo "output ok ($n secret values searched in every run)"
