# AGENTS.md

Instructions for a coding agent working in this repository.
The human reader starts at `README.md`; you start here.

## What this is

OpenWrt 25.12.6 firmware for the ZTE MF289F, built with the official ImageBuilder from one profile file.
`SPEC.md` is the source of truth: part 1 says what the image does, part 2 holds the requirements (`R14`), decisions (`D3`) and scenarios (`S4`) that code comments and test names cite.
When code and spec disagree, say so; do not silently change either.

Layout, tests and the upgrade path: `docs/development.md`.
Profile keys: `docs/profile.md`. Operator presets and how to write one: `docs/operators.md`.

## Commands

```sh
./fetch-deps.sh                          # once; downloads about 530 MB into work/
./build.sh generic                       # the secret-free image, image/generic-sysupgrade.bin
./build.sh --render-only generic tests/.out/overlay   # rendered overlay only, seconds, no ImageBuilder
tests/build/run.sh --quick               # profile checks, sh -n, rendered overlays, first boot
tests/run-all.sh                         # all rootfs tests, 6 at once (-j N or LW_JOBS), one PASS/FAIL line each
tests/run-all.sh smoke                   # the image's scripts in the OpenWrt rootfs under bwrap
tests/run-all.sh notify                  # one area: ladder | modem | notify | firstboot | smoke
tests/rootfs/run.sh tests/notify/x.sh    # one test script
shellcheck -s sh src/files/usr/sbin/lw-notify   # a changed image script; the tests are bash
```

A full `tests/build/run.sh` runs two ImageBuilder builds (about 3 minutes). `tests/vm/` needs KVM.
Tests under load can be timing-sensitive; rerun a single failing script alone before calling it a bug.
During work run the area you changed; run everything (`tests/run-all.sh`, `tests/build/run.sh`) once before you report.

## Rules

- **Private data.** `profiles/*` except `generic.conf`, `image/`, `work/` and `tests/build/private-values.txt` are the owner's and git ignores them. Never read, print or quote a private profile, a password card or a token. Report a profile problem by key name only; `build.sh` already does.
- **Test data stays fake.** Phone numbers, tokens, keys, SMS texts and device names in `tests/` are made up. Keep them that way; never paste a real value, even redacted.
- **Profiles and presets are data, not code.** `build.sh` parses `KEY='value'`; `operators.sh` parses a preset with a strict allowlist. Do not add `source`, `eval` or shell expansion to either path.
- **Modem access.** The image's scripts talk to the modem only with AT commands through `sms_tool` under `/tmp/lw-at.lock`, never raw reads of the port and never QMI. Keep it so.
- **Busybox shell.** Everything under `src/files/` runs on the router's busybox `ash`: POSIX sh, no bashisms, no GNU-only flags. The rootfs tests catch most of it; `shellcheck -s sh` catches the rest. Variables shared between the sourced `lw/*.sh` files show up there as unused; everything else it reports is real.
- **Comments say why,** and cite the spec id (`# R19: the limit counts restarts, not cycles`). No comments that narrate what the next line does.
- **Flashing and rebooting a router** are the owner's actions. Produce the image and the command; do not run `sysupgrade` or `reboot` on a router you were not told to.
- **No new background jobs** on the router (cron entries, loops, services) without the owner's word; the image already has its cron and the spec lists it.

## Adding or changing behaviour

1. Find the requirement in `SPEC.md`. New behaviour needs a new `R` id and, when it is a choice, a `D` row with its reason; put them in the spec in the same change.
2. Add or change the test first in the matching area of `tests/`; the rootfs stubs in `tests/stubs/` fake the modem and the network.
3. Change the script, run the area and `tests/build/run.sh --quick`.
4. Update `docs/` or `README.md` only where a user-visible key, command or message changed.

A change to the Telegram texts or the SMS replies is user-facing: keep the messages readable for a person without technical knowledge (spec R39), short, and in the style of the existing ones.
