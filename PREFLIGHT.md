# Preflight record

Record of the pre-publication gate run with the `preflight` skill, one section per run. Item ids point at the checklist items in the skill's `references/` (A = private, B = public, C = announce, D = contribute, other letters = modules); results are PASS, FINDINGS n resolved (n hits found and dispositioned), N/A <reason>, DEFERRED <reason, owner>, TOOL-ERROR <tool>, FAIL.

## 2026-11-08 · private · candidate 33cb2c7 · destination github:DamianPala/lonewrt (private)
Decisions: name lonewrt · licence none yet · history <unset> · maturity experimental · disclosure: "Built with AI coding agents under my direction."
Candidate 33cb2c7 was squashed into the new root before the first push; it survives only in the private history bundle.

| Item | Result | Note |
|---|---|---|
| A01 | DEFERRED (owner) | history strategy open, owner-default fields to confirm |
| A02 | DEFERRED (owner) | waits for A03 and A08 |
| A03 | DEFERRED (owner) | one commit, never pushed; squash recommended |
| A04 | PASS | history and tree clean after two non-secret hits were fixed in the root |
| A05 | N/A no credential committed | |
| A06 | FINDINGS 3 resolved | 3 kept: public operator name of the shipped preset |
| A07 | PASS | nothing private tracked; ignored local files all in stays_private |
| A08 | PASS | one identity, from the owner's defaults, to confirm |
| A09 | DEFERRED (owner) | code cites ids of a spec that stays private; decide before public |
| A10 | PASS | patterned fake data; secret-shaped fixture joined at test time; provenance line in README |
| A11 | N/A no non-text content | |
| A12 | PASS | no outside pointers, no remote |
| A13 | PASS | all first-party; packages fetched at build time |
| A14 | DEFERRED (owner) | account has 2FA; owner confirms recovery and actors |
| A15 | DEFERRED (owner) | confirm no dependents |
| A16 | N/A no remote yet | run once the owner creates the repository |
| A17 | N/A no workflows | |

## 2026-11-08 · public · candidate 4c4a617 · destination github:DamianPala/lonewrt (public)
Decisions: name lonewrt · licence MIT · history squash · maturity experimental · disclosure: "Built with AI coding agents under my direction."

| Item | Result | Note |
|---|---|---|
| A01 | PASS | every decision filled from the owner's answers |
| A02 | PASS | tree clean at the candidate |
| A03 | PASS | squash in place, bundle kept, old roots unreachable, never pushed |
| A04 | PASS | secret scans clean |
| A05 | N/A no credential committed | |
| A06 | FINDINGS 9 resolved | process words cut from test comments; account line, identity and operator preset name kept |
| A07 | PASS | private working files excluded locally, not named in .gitignore |
| A08 | PASS | one approved identity |
| A09 | PASS | English spec ships, ids stable; docs edited for plain English |
| A10 | PASS | only patterned fake data |
| A11 | N/A no non-text content | |
| A12 | PASS | no outside pointers |
| A13 | PASS | first-party; packages fetched at build time, sha256 pinned |
| A14 | PASS | 2FA on; recovery and actors confirmed by the owner |
| A15 | PASS | no dependents |
| A16 | PASS | public, not a fork, empty, owner only, no secrets |
| A17 | N/A no workflows | |
| B01 | PASS | published set = all except the private list |
| B02 | PASS | MIT in LICENSE and README; nothing vendored |
| B03 | PASS | name free on GitHub and PyPI |
| B04 | PASS | fresh clone, empty home, full download, build and tests |
| B05 | PASS | README walked; terms, maintenance, security route present |
| B06 | PASS | deliberate break caught; clear error on a missing key |
| B07 | PASS | network destinations listed; hostile SMS test added |
| B08 | PASS | pinned downloads live; post-release fixes already in the image |
| B09 | N/A no release version | |
| B10 | N/A no CI | |
| B11 | N/A no distributed artefact | |
| B12 | PASS | squashed hashes point at the history bundle |
| B13 | PASS | secret scanning, push protection, private vulnerability reporting on |
| B14 | DEFERRED after the owner's upload | fresh clone from the public URL |
| B15 | PASS | status names the destination and the source of truth |
| B16 | N/A no agent instructions shipped | |
| L13 | PASS | no credentials or ids in shipped files |
| L14 | PASS | outward steps listed, confirmations, dry run, kill switch |
| L15 | PASS | reruns send no duplicates (tests) |
| L16 | PASS | no model; endpoints and failure modes documented |
| L21 | FINDINGS 1 resolved | build.sh now checks its host programs first |
