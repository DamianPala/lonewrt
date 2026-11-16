#!/usr/bin/env bash
# SPEC R53a, R53i, R53j, R54, D110, D112, D119: every gate of ci/github-run.sh stops the run with an
# ::error:: line before the build, writes nothing to the output folder, and leaves no profile file.
# shellcheck source=tests/ci/lib.bash
source "$(dirname "$0")/lib.bash"
ci_setup gates
P=$SCRATCH/profile.conf
OTHER=$SCRATCH/other.conf
# a profile of other secret values than the run fixture, for the test run that must ignore it
variant "$OTHER" -e "s/^WIFI_KEY=.*/WIFI_KEY='other-wifi-key-z4k8'/" \
    -e "s/^TG_BOT_TOKEN=.*/TG_BOT_TOKEN='123456789:OTHERtokenz4k8-ZZZZZZZZZZZZZZZZZZZZZZZZZZ'/"

# R54: a public repository, no test mark: stops before anything runs, and says why and how
for private in false '' maybe; do
    ci_run "$FX" LW_REPO_PRIVATE="$private"
    ci_expect_stop "public" "signed-in GitHub user" "Change visibility"
    [ ! -s "$REC/calls" ] || fail "R54: a public run called a build step before it stopped: $(cat "$REC/calls")"
done
# only the value "true" marks a test
ci_run "$FX" LW_REPO_PRIVATE=false LW_TEST=yes
ci_expect_stop "public"

# R54, D119: public and marked as a test: builds the run fixture whatever LW_PROFILE holds, the
# summary starts with the warning, and the run does not even need the secret
for held in "$OTHER" /dev/null; do
    ci_run "$held" LW_REPO_PRIVATE=false LW_TEST=true
    ci_expect_ok
    cmp -s "$REC/profile-seen" "$FX" || fail "R54: the test run did not build the run fixture"
    head -n 1 "$SUMMARY" | grep -q 'open to every signed-in GitHub user' ||
        fail "R54: the summary does not start with the warning: $(head -n 1 "$SUMMARY")"
    grep -q '^::warning::' "$RUN_OUT" || fail "R54: no ::warning:: annotation of the test run"
    [ -f "$CI_OUT/router-sysupgrade.bin" ] || fail "R54: the test run has no image"
done
# the fixture is the one thing built: nothing of the other profile reached the build
ci_run "$OTHER" LW_REPO_PRIVATE=false LW_TEST=true
! grep -qF other-wifi-key-z4k8 "$REC/profile-seen" || fail "R54: LW_PROFILE reached the build of a test run"

# R54: a private repository gets neither the stop nor the warning, and a test mark changes nothing:
# it builds LW_PROFILE
ci_run "$OTHER" LW_TEST=true
ci_expect_ok
cmp -s "$REC/profile-seen" "$OTHER" || fail "R54: a private test run did not build LW_PROFILE"
! grep -qi 'warning' "$SUMMARY" "$RUN_OUT" || fail "R54: a private repository got a warning"

# R53a: LW_PROFILE missing, empty or blank names the secret and where to set it
for blank in "" "   "; do
    printf '%s\n' "$blank" >"$P"
    ci_run "$P"
    ci_expect_stop "LW_PROFILE" "Secrets and variables"
    [ ! -s "$REC/calls" ] || fail "R53a: a build step ran without a profile"
done

# R53j: the name follows build.sh's rule, and generic is taken (it is the reference of R3)
for bad in generic '../x' 'a b' -x 'a;b' "$(printf 'x\ny')"; do
    ci_run "$FX" LW_NAME="$bad"
    ci_expect_stop "profile name"
    ci_called 'build.sh' && fail "a build step ran for the name '$bad'"
done
[ "$(git -C "$REPO" status --porcelain | wc -l)" = 0 ] || fail "the run changed the checkout"

# a profile the owner keeps under that name is never overwritten
mkdir -p "$REPO/profiles"
echo "KEEP='mine'" >"$REPO/profiles/router.conf"
RC=0
(cd "$REPO" && env -i PATH="$BIN" HOME="$SCRATCH" TMPDIR="$SCRATCH/tmp" STUB_REC="$SCRATCH/rec" \
    LW_REPO_PRIVATE=true LW_PROFILE="x='y'" bash ci/github-run.sh) >"$SCRATCH/keep.out" 2>&1 || RC=$?
[ "$RC" != 0 ] || fail "a run overwrote an existing profiles/router.conf"
[ "$(cat "$REPO/profiles/router.conf")" = "KEEP='mine'" ] || fail "an existing profiles/router.conf was changed or removed"
rm "$REPO/profiles/router.conf"

# a checkout whose VERSION is not the version the workflow asked for
ci_run "$FX" LW_VERSION=9.9.9
ci_expect_stop "9.9.9"
ci_run "$FX" LW_VERSION="v$(cat "$FW/VERSION")"
ci_expect_ok

# R53i, D112: no WIFI_KEY, or neither root password: stops before the build and names the keys
variant "$P" -e "s/^WIFI_KEY=.*/WIFI_KEY=''/"
ci_run "$P"
ci_expect_stop "WIFI_KEY" "both passwords"
! ci_called '^build.sh [a-z]' || fail "R53i: the build ran with an empty WIFI_KEY"
variant "$P" -e "s/^ROOT_PASSWORD_HASH=.*/ROOT_PASSWORD_HASH=''/"
ci_run "$P"
ci_expect_stop "ROOT_PASSWORD" "ROOT_PASSWORD_HASH" "every run gives the same"
! ci_called '^build.sh [a-z]' || fail "R53i: the build ran with no root password"
variant "$P" -e "s/^WIFI_KEY=.*/WIFI_KEY=''/" -e "s/^ROOT_PASSWORD_HASH=.*/ROOT_PASSWORD_HASH=''/"
ci_run "$P"
ci_expect_stop "WIFI_KEY" "ROOT_PASSWORD"
# R33b: either root key is enough
variant "$P" -e "s/^ROOT_PASSWORD_HASH=.*/ROOT_PASSWORD_HASH=''/" -e "s/^ROOT_PASSWORD=.*/ROOT_PASSWORD='fake-root-pw-q7x9'/"
ci_run "$P"
ci_expect_ok

# R53c: the file is written as a CRLF text arrives from a browser, and is read as LF, mode 0600
sed 's/$/\r/' "$FX" >"$P"
ci_run "$P"
ci_expect_ok
[ "$(cat "$REC/profile-mode")" = 600 ] || fail "R53c: the profile file had mode $(cat "$REC/profile-mode")"
! grep -q $'\r' "$REC/profile-seen" || fail "R53c: the profile file still has CRLF line ends"
cmp -s "$REC/profile-seen" "$FX" || fail "R53c: the profile file differs from LW_PROFILE after the CR is dropped"
! ci_called 'saw LW_PROFILE' || fail "R53b: build.sh inherited LW_PROFILE"

# R53a: a profile that build.sh refuses stops the run with build.sh's message (the real one here),
# which names the key and, R3, never a value
ci_repo real
variant "$P" '/^LAN_IP=/d'
ci_run "$P"
ci_expect_stop "LAN_IP" "refused"
variant "$P" -e "s/^WIFI_KEY=.*/WIFI_KEY='shortpw'/"
ci_run "$P"
ci_expect_stop "WIFI_KEY"
! grep -qF shortpw "$RUN_OUT" || fail "R3: the message echoes the WiFi key"
variant "$P" -e "s/^TG_BOT_TOKEN=.*/TG_BOT_TOKEN='badtoken-q7x9'/"
ci_run "$P"
ci_expect_stop "TG_BOT_TOKEN"
! grep -qF badtoken-q7x9 "$RUN_OUT" || fail "R3: the message echoes the bot token"
echo "gates ok"
