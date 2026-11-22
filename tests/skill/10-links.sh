#!/usr/bin/env bash
# SPEC R59d, R59f, R59: the agent skill is skills/lonewrt/SKILL.md with the frontmatter name lonewrt
# and a description, README.md and AGENTS.md link to it, and it keeps the commands and rules the
# spec asks for (the gates of a flash, the secret handed to GitHub on stdin, the 0600 copy). The check
# is also run on damaged scratch copies and must fail naming the culprit. R62: the porting guide
# docs/porting.md exists and README.md and AGENTS.md link to it.
# shellcheck source=tests/build/lib.bash
source "$(dirname "$0")/../build/lib.bash"
scratch skilllinks
SKILL=skills/lonewrt/SKILL.md

# check_tree DIR: the checks, against the files of DIR; prints the first problem and returns 1
check_tree() {
    local d=$1 f=$1/$SKILL phrase
    [ -f "$f" ] || { echo "R59d: $SKILL is missing"; return 1; }
    [ "$(sed -n 1p "$f")" = '---' ] || { echo "R59d: $SKILL does not start with frontmatter"; return 1; }
    local front
    front=$(awk 'NR == 1 { next } /^---$/ { exit } { print }' "$f")
    grep -qx 'name: lonewrt' <<<"$front" || { echo "R59d: frontmatter lacks 'name: lonewrt'"; return 1; }
    grep -qE '^description: ".{40,}' <<<"$front" || { echo "R59d: frontmatter has no description"; return 1; }
    grep -qF "](${SKILL})" "$d/README.md" || { echo "R59d: README.md does not link to $SKILL"; return 1; }
    grep -qF "](${SKILL})" "$d/AGENTS.md" || { echo "R59f: AGENTS.md does not link to $SKILL"; return 1; }
    grep -qF 'agent skill' "$d/AGENTS.md" || { echo "R59f: AGENTS.md does not name the agent skill"; return 1; }
    # the rules and commands of R59 to R59g that an agent must find in the file
    # shellcheck disable=SC2016  # the backticks are text of the skill, not a command
    for phrase in 'install -m 0600' './fetch-deps.sh' './build.sh <name>' 'explicit yes' 'sysupgrade -b' \
        'scp -O' 'sysupgrade -T' 'sysupgrade -n' 'someone is at the router' 'gh secret set LW_PROFILE' \
        'gh repo create' '--template DamianPala/lonewrt-build' '--private' 'ssh-keygen -R' \
        'Never set the `test` input' 'No secret value ever reaches the chat' 'file-reading tool' \
        'Recovery'; do
        grep -qF -- "$phrase" "$f" || { echo "R59: $SKILL lacks '$phrase'"; return 1; }
    done
    # a secret is never given in an argument of the secret command
    ! grep -qE 'gh secret set LW_PROFILE.*(--body|-b )' "$f" || { echo "R59g: the skill sends the secret in an argument"; return 1; }
    return 0
}

out=$(check_tree "$FW") || fail "$out"

# R62: the porting guide exists, and README.md and AGENTS.md link to it
[ -f "$FW/docs/porting.md" ] || fail "R62: docs/porting.md is missing"
for f in README.md AGENTS.md; do
    grep -qF '](docs/porting.md)' "$FW/$f" || fail "R62: $f does not link to docs/porting.md"
done

# expect_refused TREE-CHANGE MESSAGE: a copy of the three files with one change must fail the check
mkdir -p "$SCRATCH/t/skills/lonewrt"
refused=0
damaged() { # damaged MESSAGE FILE SED-ARGS...
    local message=$1 file=$2 got
    shift 2
    cp "$FW/README.md" "$FW/AGENTS.md" "$SCRATCH/t/"
    cp "$FW/$SKILL" "$SCRATCH/t/$SKILL"
    sed -i "$@" "$SCRATCH/t/$file"
    refused=$((refused + 1))
    if got=$(check_tree "$SCRATCH/t"); then fail "the check passed although '$message' was expected"; fi
    grep -qF -- "$message" <<<"$got" || fail "the check said '$got', not '$message'"
}
damaged "frontmatter lacks 'name: lonewrt'" "$SKILL" 's/^name: lonewrt$/name: other/'
damaged "README.md does not link" README.md 's|](skills/lonewrt/SKILL.md)|](docs/x.md)|g'
damaged "AGENTS.md does not link" AGENTS.md 's|](skills/lonewrt/SKILL.md)|](docs/x.md)|g'
damaged "lacks 'sysupgrade -T'" "$SKILL" 's/sysupgrade -T/sysupgrade -X/g'
damaged "lacks 'someone is at the router'" "$SKILL" 's/someone is at the router/anyone/g'
damaged "sends the secret in an argument" "$SKILL" 's|gh secret set LW_PROFILE --repo <owner>/<repo> <|gh secret set LW_PROFILE --body x <|'
echo "skill file, links and rules ok; $refused damaged copies refused"
