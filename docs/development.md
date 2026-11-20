# Development

## Build host

Linux x86_64 with `bash`, `python3`, `openssl`, `curl`, `tar`, `zstd`, `make`, `flock` (util-linux) and GNU awk.
Without `gawk`, `fetch-deps.sh` unpacks Ubuntu's, which needs `dpkg-deb` and glibc 2.38 or newer.
The tests need `bubblewrap`, `squashfs-tools`, `qrencode` and `zbar-tools` (without the last two the two host tests print `SKIP`); the VM bench also `qemu-system-x86_64` and `/dev/kvm`.
`build.sh` checks for its programs before it starts and names the missing one.
A build and the VM image also need the network: they fetch the `uqmi` package from the package feeds of the ImageBuilder to derive `qmi.sh` from it (SPEC R12d).

```sh
./build.sh --render-only mine tests/.out/overlay   # only the rendered rootfs overlay, no ImageBuilder
./fetch-deps.sh --help                       # download groups: ib extra gawk rootfs jpeg vm rescue
```

## Where things are

| Path | What | Git |
|---|---|---|
| `build.sh`, `src/render.py` | profile checks, overlay, ImageBuilder run | yes |
| `VERSION` | the release version, one line; the build puts it into `/etc/lw-build` (SPEC R3b), see Release below | yes |
| `qmi-handler.sh` | takes `/lib/netifd/proto/qmi.sh` from the `uqmi` package of the ImageBuilder, drops its `--network-scan` line (the build stops unless the line is there exactly once) and checks the image's copy after `make image`; sourced by `build.sh` and `tests/vm/build-image.sh`. The repository holds no copy of the file (SPEC R12d, D82) | yes |
| `pinned-packages.sh` | the checked copy of the third-party `.apk` files into an ImageBuilder, sourced by `build.sh` and `tests/vm/build-image.sh` | yes |
| `src/files/` | the files of the image (init scripts, `wwan-recover`, `lw-notify`, `uci-defaults/zz-lw-config`, cron, ...) | yes |
| `src/files/usr/share/lw/operators/` | operator presets, one data file per MCC-MNC (`29702`), see [operators.md](operators.md) | yes |
| `profiles/generic.conf` | the template profile and the list of all keys, see [profile.md](profile.md) | yes |
| `profiles/<name>.conf`, `profiles/<name>/` | your profiles and their SSH key files | no |
| `image/` | build output: `<name>-sysupgrade.bin`, `.manifest`, `<name>-passwords.txt` | no |
| `work/` | ImageBuilder, downloads, VM bench (`LW_WORK` moves it) | no |
| `fetch-deps.sh`, `deps.lst` | downloads with pinned sha256 | yes |
| `configurator/index.html` | the configurator: one file with inline style and script that writes a profile (SPEC R56 to R58a); it holds the release version it belongs to in the constant `LW_VERSION`, which moves with `VERSION` at a release (the test compares them). `.github/workflows/pages.yml` publishes it to GitHub Pages when a release is published (D123) | yes |
| `ci/github-run.sh` | the steps of a build run on GitHub: checks, dependencies, build, tests, files for the artifact, summary (SPEC R53 to R54). The workflow of the template repository only calls it, so a change here ships with the next release (D118) | yes |
| `skills/lonewrt/SKILL.md` | the agent skill: how a coding agent builds and flashes a person's image without showing a secret of the profile (SPEC R59 to R59g) | yes |
| `tests/` | tests; reports and scratch in `tests/.out/` | yes |
| `SPEC.md` | what the image does and why, with requirement ids (`R14`) and decision ids (`D3`) that the code comments cite | yes |
| `packages.md` | the packages in the image and the ones left out | yes |

## Tests

| Command | What it checks |
|---|---|
| `tests/run-all.sh [-j N] [area]` | the scripts of the image inside the official OpenWrt x86_64 rootfs (same busybox, `uci`, `jsonfilter`) under `bwrap`, with modem and network as stubs: recovery ladder, APN, SMS, notifications, first boot, the data session watcher (stand-ins for `uqmi`, `ip`, `sleep` and the signals to `udhcpc` in `tests/linkwatch/stubs/`). Areas: `ladder modem notify firstboot smoke linkwatch` |
| `tests/run-all.sh hostnet` (also the last step of `tests/run-all.sh`) | the two checks that need the host: the upload of the QR photo (R51) from the image's own code and the rootfs's `uclient-fetch` to a python3 server on 127.0.0.1 that parses the multipart body, and the QR picture of `/wifi` made by the image's own `nt_qr_image` pipeline (host `qrencode` text, the awk filter, the real `cjpeg` from `./fetch-deps.sh jpeg`) and read back as the same text by `zbarimg`, for 19 names and passwords with every special character. They print `SKIP` when the host lacks a tool, a namespace or a port |
| `tests/build/run.sh [--quick]` | profile validation, `sh -n` with the rootfs busybox, rendered overlays, `.gitignore`, the `qmi.sh` derivation against a stand-in package, then the first-boot tests; without `--quick` also two real ImageBuilder builds (about 3 minutes, network needed for `uqmi`) that check the image's `qmi.sh` against the package's |
| `tests/ci/run.sh` | `ci/github-run.sh` on the host, in a scratch copy of the repository with stand-ins for `build.sh`, `fetch-deps.sh` and the two test runners (and a recorder for `sudo`): the gates (public repository, secret, name, profile, passwords), a test that fails or prints `SKIP`, the files and the summary of a good run, and that no secret value of the profile and no profile file is left (R53 to R54). It takes seconds and builds nothing; `tests/run-all.sh` does not run it |
| `tests/configurator/run.sh` | the configurator `configurator/index.html` (R56 to R58a) and `.github/workflows/pages.yml`. `10-static.sh` needs only `python3`: every key of `generic.conf` is on the page, in its order, with its default and the empty-allowed flag of `render.py`, no key the file lacks, a select only where it offers every value `build.sh` accepts, the version constant equals `VERSION`, nothing that loads or calls out and no browser storage, and the Pages workflow pins its actions; each rule is also run against a damaged scratch copy and must fail naming the culprit. `20-browser.sh` opens the file from disk in a headless browser with `agent-browser` (prints `SKIP` without it): the unchanged form is accepted by `build.sh --render-only`, the run fixture typed in comes out key by key, loading marks new and left-out keys, the rough checks and the password note, a reload and empty storage, and a request log that holds only the file. It builds nothing and uses `LW_WORK` only for the `sh -n` of the render check; `tests/run-all.sh` does not run it |
| `tests/skill/run.sh` | the agent skill `skills/lonewrt/SKILL.md` (R59 to R59g): `10-links.sh` checks the frontmatter (`name: lonewrt`, a description), that `README.md` and `AGENTS.md` link to it, that the commands and rules of a flash, of the GitHub secret and of the 0600 copy are in it, and refuses six damaged copies; `20-tunnel-compare.sh` runs the comparison block of the skill (step 7.1) against made-up values and a stand-in for `ssh`, and checks that it names the keys that differ and prints no value. Seconds, needs nothing but `bash`; `tests/run-all.sh` does not run it |
| `tests/vm/run-all.sh` | an x86 image in QEMU/KVM with a stand-in for the modem: first boot, no modem, power cut during first boot, reset, cron, log rotation, modem mode; see `tests/vm/README.md` |

All test data is made up: phone numbers, names, keys, tokens, SMS texts and device names in `tests/` belong to nobody.
The build tests use `tests/build/fixtures/fake-full.conf`, a profile of made-up values, and check that the generic image contains none of them.
Put values of your own private profile, one per line, into `tests/build/private-values.txt` (git ignores it) to check that they never reach the generic image either.

`tests/run-all.sh` runs 6 tests at once (`-j N` or `LW_JOBS`); the report keeps the listing order.
A change in one area needs that area during the work and the full run once before it is reported.

The run on GitHub itself is only partly testable here: its user-namespace setting, the `apt` install, the template's workflow and the artifact upload need a runner. To try the script end to end on this machine, run it with a profile in `LW_PROFILE` (the fixture of `tests/build/lib.bash` will do), `LW_REPO_PRIVATE=true` and `LW_WORK` set; the files go to `out/` (`LW_OUT_DIR`).

Not testable without the router: the real modem and operator network (bands, APN, 2G fallback), WiFi, the ipq40xx kernel.

## Screenshots of the Telegram bot

`tools/tg-preview/` makes phone-style screenshots of the bot's chat, to see how the messages look and for the README.
It plays a made-up chat through the bot's real code in the test rootfs, so the texts are the bot's own, and renders it as Telegram for Android (dark) with headless Chrome.
It is a laptop tool: it needs `python3`, `qrencode` (draws the Wi-Fi photo, R51), `bwrap` with the rootfs of `./fetch-deps.sh`, and `google-chrome` (or `chromium`, or `TGP_CHROME`); nothing changes on a router or in the image.

```sh
tools/tg-preview/run.sh                            # PNGs and index.html in tests/.out/tg-preview/
tools/tg-preview/run.sh --transcript chat.json     # a hand-written chat, for a message that has no code yet
```

The transcript format and the options are in `tools/tg-preview/README.md`; `tools/tg-preview/test.sh` checks the scenario and the renderer without a browser.

## Release

The release version is the one line of `VERSION` at the repository root (`0.4.0`; a pre-release is `0.5.0-rc.1`, SPEC R3b).
The build puts it into `/etc/lw-build` and the first line of the `lw-firstboot` log entry, so a router tells which release it runs.
To release: change `VERSION` and `LW_VERSION` in `configurator/index.html`, commit, tag that commit `v<version>`, then build. Publishing the release (not a pre-release) starts `.github/workflows/pages.yml`, which puts that tag's configurator on GitHub Pages; its actions are pinned to commits and move only by hand.
A build stops when `VERSION` is missing or malformed.

## Recovery

The MF289F has no button recovery.
If the system is damaged, the only way back is the serial console: open the case, attach a UART adapter, interrupt U-Boot, load the `initramfs` image over TFTP (`./fetch-deps.sh rescue` downloads it; the laptop is `192.168.0.2`), boot it and run `sysupgrade` from there.
This is why images are flashed only after `sysupgrade -T` passes, and why the kernel is the official one.

## New OpenWrt version

1. Change the version in `build.sh` and `tests/vm/build-image.sh` (`IB_TAR`), `fetch-deps.sh` (file names in `unpack_rootfs`) and `deps.lst` (URLs and sha256 from the `sha256sums` file of each download directory).
2. Fetch the third-party `.apk` files again for that version: the feed `dl.eko.one.pl/openwrt-<release>/packages/<arch>/base/` for `modemband` and `modemdata`, the GitHub releases of 4IceG for the `luci-app-*`.
3. Compare the default configuration with what `zz-lw-config` changes (it sets only the differences).
4. Refresh the x86 rootfs for the tests. Then `tests/configurator/run.sh` compares the configurator's zone table with LuCI's `zoneinfo.uc` of that rootfs; copy the new table into `configurator/index.html` when they differ (the build fills an empty `TIMEZONE` from it, SPEC R3c).
5. Read `/lib/netifd/proto/qmi.sh` of the new `uqmi` package. The build stops, naming the file, when the `--network-scan` line is not there exactly once; check that the new handler still scans only after the mode set, change `qmi-handler.sh` if it does not, and time `ifup wwan` on the router again (SPEC D82: about 15 s to the first ping, 40 s with the scan).
