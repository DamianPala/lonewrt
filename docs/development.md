# Development

## Build host

Linux x86_64 with `bash`, `python3`, `openssl`, `curl`, `tar`, `zstd`, `make`, `flock` (util-linux) and GNU awk.
Without `gawk`, `fetch-deps.sh` unpacks Ubuntu's, which needs `dpkg-deb` and glibc 2.38 or newer.
The tests need `bubblewrap` and `squashfs-tools`; the VM bench also `qemu-system-x86_64` and `/dev/kvm`.
`build.sh` checks for its programs before it starts and names the missing one.

```sh
./build.sh --render-only mine tests/.out/overlay   # only the rendered rootfs overlay, no ImageBuilder
./fetch-deps.sh --help                       # download groups: ib extra gawk rootfs vm rescue
```

## Where things are

| Path | What | Git |
|---|---|---|
| `build.sh`, `src/render.py` | profile checks, overlay, ImageBuilder run | yes |
| `src/files/` | the files of the image (init scripts, `wwan-recover`, `lw-notify`, `uci-defaults/zz-lw-config`, cron, ...) | yes |
| `src/files/usr/share/lw/operators/` | operator presets, one data file per MCC-MNC (`29702`), see [operators.md](operators.md) | yes |
| `profiles/generic.conf` | the template profile and the list of all keys, see [profile.md](profile.md) | yes |
| `profiles/<name>.conf`, `profiles/<name>/` | your profiles and their SSH key files | no |
| `image/` | build output: `<name>-sysupgrade.bin`, `.manifest`, `<name>-passwords.txt` | no |
| `work/` | ImageBuilder, downloads, VM bench (`LW_WORK` moves it) | no |
| `fetch-deps.sh`, `deps.lst` | downloads with pinned sha256 | yes |
| `tests/` | tests; reports and scratch in `tests/.out/` | yes |
| `SPEC.md` | what the image does and why, with requirement ids (`R14`) and decision ids (`D3`) that the code comments cite | yes |
| `packages.md` | the packages in the image and the ones left out | yes |

## Tests

| Command | What it checks |
|---|---|
| `tests/run-all.sh [area]` | the scripts of the image inside the official OpenWrt x86_64 rootfs (same busybox, `uci`, `jsonfilter`) under `bwrap`, with modem and network as stubs: recovery ladder, APN, SMS, notifications, first boot. Areas: `ladder modem notify firstboot smoke` |
| `tests/build/run.sh [--quick]` | profile validation, `sh -n` with the rootfs busybox, rendered overlays, `.gitignore`, then the first-boot tests; without `--quick` also two real ImageBuilder builds (about 3 minutes) |
| `tests/vm/run-all.sh` | an x86 image in QEMU/KVM with a stand-in for the modem: first boot, no modem, power cut during first boot, reset, cron, log rotation, modem mode; see `tests/vm/README.md` |

All test data is made up: phone numbers, names, keys, tokens, SMS texts and device names in `tests/` belong to nobody.
The build tests use `tests/build/fixtures/fake-full.conf`, a profile of made-up values, and check that the generic image contains none of them.
Put values of your own private profile, one per line, into `tests/build/private-values.txt` (git ignores it) to check that they never reach the generic image either.

Not testable without the router: the real modem and operator network (bands, APN, 2G fallback), WiFi, the ipq40xx kernel.

## Recovery

The MF289F has no button recovery.
If the system is damaged, the only way back is the serial console: open the case, attach a UART adapter, interrupt U-Boot, load the `initramfs` image over TFTP (`./fetch-deps.sh rescue` downloads it; the laptop is `192.168.0.2`), boot it and run `sysupgrade` from there.
This is why images are flashed only after `sysupgrade -T` passes, and why the kernel is the official one.

## New OpenWrt version

1. Change the version in `build.sh` and `tests/vm/build-image.sh` (`IB_TAR`), `fetch-deps.sh` (file names in `unpack_rootfs`) and `deps.lst` (URLs and sha256 from the `sha256sums` file of each download directory).
2. Fetch the third-party `.apk` files again for that version: the feed `dl.eko.one.pl/openwrt-<release>/packages/<arch>/base/` for `modemband` and `modemdata`, the GitHub releases of 4IceG for the `luci-app-*`.
3. Compare the default configuration with what `zz-lw-config` changes (it sets only the differences).
4. Refresh the x86 rootfs for the tests.
