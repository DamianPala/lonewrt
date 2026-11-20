# Porting lonewrt to another router

lonewrt is built for one router, the ZTE MF289F, but much of it does not care which router it runs on.
This page is for a coding agent that moves it to another OpenWrt router with an LTE modem, working with the person who owns that router.
It lists what stays, what changes and what must be measured again on the new hardware.

The person decides, the agent does the work.
A port lives in a fork of this repository; this repository builds only the MF289F.

## Before you start

Find out with the person, and write it down in the fork's `SPEC.md` (part 1 and the Terms):

- **The router and its OpenWrt.** The new router needs an official OpenWrt 25.12.6 build: lonewrt uses the official ImageBuilder and kernel (SPEC R1, D1), never a custom one. Note the target, subtarget and device profile, from the router's page on openwrt.org or `profiles.json` of the target's download folder.
- **How the modem talks.** QMI (`uqmi`, `/dev/cdc-wdm0`, `proto qmi`), MBIM (`umbim`, `proto mbim`), ModemManager (`proto modemmanager`) or a modem in router mode that hands out DHCP. lonewrt's link layer is QMI; anything else changes step 2 below.
- **The modem's AT dialect.** The make and model of the modem inside (`ATI` on its AT port). lonewrt sends ZTE commands for the radio mode and the bands; another vendor has other commands.
- **How to get back from a bad image.** The MF289F can only be recovered over UART with the case open. The new router may have a failsafe mode, a recovery button or a TFTP recovery in its bootloader. Know which one before the first flash, and tell the person.
- **The router must already run official OpenWrt**, so its stock settings can be read (below) and a lonewrt image goes on with `sysupgrade`.

## Read the new router first

On the router with stock official OpenWrt, before changing any code. These commands only read, and they print no password or key:

```sh
ubus call system board                     # target, board name, OpenWrt version
ls -l /dev/ttyUSB* /dev/cdc-wdm* /dev/wwan* 2>/dev/null
ip -br link                                # the name of the modem's network device
uci show network  | grep -vE '\.(private_key|preshared_key|password|key)='
uci show wireless | grep -vE '\.(key|password)='
```

Never print `uci export` or a whole config file into the chat: they hold the Wi-Fi password, WireGuard keys and the APN password.

Find the AT port by sending `ATI` to each `ttyUSB` with `sms_tool -d /dev/ttyUSBn at ATI`. Ask the person before each port: a port that is not an AT port can hang a modem, and a raw read of a port (`cat`) never belongs in a script.
If `sms_tool` is missing, installing it writes to flash; ask first, and say that this is the only write of the survey.

## What stays

These parts know nothing about the router and move unchanged:

- the profile format and its checks in `src/render.py` (apart from the card text, below), the password card, `docs/profile.md`;
- the Telegram bot's commands and texts, the SMS forwarding and the SMS commands, the balance check and the operator presets (those belong to the SIM, not to the router);
- the logic of the recovery ladder (`wwan-recover`): its waits, classes and state;
- WireGuard, firewall, LAN, system settings, logs, cron and watchcat in `src/files/etc/uci-defaults/zz-lw-config`;
- most tests of those parts: `tests/notify` (apart from `isolation.sh`), `tests/hostnet`, `tests/configurator`, `tests/ci`, most of `tests/build`.

These move with small edits:

- `lw-notify` and `src/files/usr/lib/lw/speedtest.sh`: the modem's network device `wwan0` and the SMS store `ME` (steps 3 and 4);
- the card text in `src/render.py`: the router's name, the two bands and the SMS thresholds;
- the configurator: its Wi-Fi defaults, which `tests/configurator` keeps equal to `generic.conf`;
- the GitHub build and the agent skill, which name this repository (step 7).

## What changes

### 1. Target, packages and image name

- `build.sh`: `IB_TAR` (the ImageBuilder file name), `PROFILE=zte_mf289f` in the ImageBuilder call, and the glob that finds the image after `make image` (`*-$name-*-squashfs-sysupgrade.bin`; other routers name it `.itb` or differently). `build.sh` always publishes it as `image/<name>-sysupgrade.bin`, so nothing after it depends on the ImageBuilder's name.
- `deps.lst`: the ImageBuilder URL and sha256; the `dl.eko.one.pl` folder of `modemband` and `modemdata` carries the CPU architecture (`arm_cortex-a7_neon-vfpv4` for ipq40xx); the `rescue` group holds MF289F images.
- Packages: the ImageBuilder's device profile brings the modem and Wi-Fi drivers; check its default packages for `kmod-usb-net-qmi-wwan` (or the MBIM one), `kmod-usb-serial-option` and `uqmi`. `tests/build/60-images.sh` (full `tests/build/run.sh` only) compares `PACKAGES` of `build.sh` with `packages.md` but leaves the device's default set out of the comparison: a driver the new profile lacks goes into `PACKAGES` and its own row of `packages.md`, and the filter in that test changes with it. `tests/vm/build-image.sh` has its own list and follows the same change.
- `tests/build/lib.bash` (`unpack_image`) expects the NAND tar image of the MF289F.
- Check the image size against the router's flash: nothing in the build does that.

### 2. Modem connection

lonewrt uses QMI through netifd's `qmi.sh` (`network.wwan.proto=qmi`, `device=/dev/cdc-wdm0`, `modes`, `timeout` in `zz-lw-config`).

- `qmi-handler.sh` derives `qmi.sh` from the `uqmi` package without its `--network-scan` line (SPEC R12d, D82). It is QMI only. With QMI, keep it and time `ifup wwan` again. With MBIM or ModemManager, remove it and everything that uses it: its calls in `build.sh` and `tests/vm/build-image.sh`; `tests/build/45-qmi-handler.sh`; `check_qmi` in `tests/build/60-images.sh`; the qmi part of `tests/build/15-pinned-packages.sh`, with `fake_qmi_ib` and `fake_make_image` in `tests/build/lib.bash` and their fixtures; the copy in `tests/ci/lib.bash`; and the `qmi.sh` check of Acceptance point 2.
- `lw-linkwatch` restores a dropped QMI data session in place (SPEC R49 to R49g). It needs `uqmi`, netifd's `cid_4`/`pdh_4` and `udhcpc`. With another protocol, remove it (`src/files/etc/init.d/lw-linkwatch`, `usr/sbin/lw-linkwatch`, `tests/linkwatch/`, its entries in `tests/build/60-images.sh` and `tests/vm/10-firstboot.sh`, and its mentions in `packages.md`, `docs/profile.md`, `generic.conf`, `docs/development.md`, R12c and Acceptance point 2) or write the equivalent. Nothing else calls it; the ladder still repairs the link, only more slowly.
- `network.wwan.modes` is also how the EDGE fallback works (`lw-modem-mode`, `lw-fallback`); give it the new protocol's equivalent, or drop the fallback with the person's word.
- `luci-proto-qmi` in `PACKAGES` becomes the protocol's LuCI package.

### 3. Ports and device names

- The scripts' AT port: `LW_AT_PORT` in `src/files/usr/lib/lw/common.sh` (`/dev/ttyUSB2`); `tests/rootfs/run.sh` binds that same name for the tests. The port for LuCI and manual work: the `sms_tool_js`, `modemband` and `defmodems` blocks of `zz-lw-config` (`/dev/ttyUSB1`). Keep two ports when the modem has them, so LuCI and the scripts do not share one.
- Every script takes `/tmp/lw-at.lock` before it touches the scripts' port (`lw_at`, or `flock` around `sms_tool` and `md_serial_ecm`). Keep it so (AGENTS.md).
- The modem's network device `wwan0` is written into `wwan-recover`, `lw-siglog`, `lw-notify` and `speedtest.sh`.
- `defmodems.mf289f` in `zz-lw-config` is a label for `modemdata`; `tests/firstboot/generic.sh` checks it.

### 4. Vendor AT commands and the SMS store

The ZTE commands, and where they are sent:

| Command | Script | What for |
|---|---|---|
| `AT+ZSNT?` | `lw-modem-mode`, `lw-siglog`, `wwan-recover` | the stored radio mode (SPEC R10, R11); `wwan-recover` ends a failure after an LTE probe only on `ZSNT: 6,` (R23) and puts the answer in its snapshot |
| `AT+ZSNT=6,0,0` | `lw-modem-mode`, `lw-fallback lte` | LTE only |
| `AT+ZSNT=0,0,0` | `lw-fallback edge` | automatic mode for the EDGE fallback (SPEC R22, R23) |
| `AT+ZNLOCKBAND?`, `AT+ZNLOCKBAND=1,0,<mask>,0` | `lw-modem-mode` | the bands of `LTE_BANDS`; `lwmm_mask` turns the list into a bit mask at every start (SPEC R12) |

Everything else is standard 3GPP (`CPIN`, `CIMI`, `CPMS`, `CEREG`, `COPS`, `CSQ`, `CEER`, `CGATT`, `CGPADDR`) and SMS goes through `sms_tool`. Signal and band names come from `md_serial_ecm` of the `modemdata` package; a modem it does not know gives `?` fields in `lw-siglog`.

The SMS store `ME` is written into `lw-modem-mode` (it sets `"ME","ME","ME"` at every start, R11), `lw-notify`, `notify.sh`, `lw-sms-clean` and the `sms_tool_js` block of `zz-lw-config`. A modem without `ME` changes all of them and R11, R26.

For another vendor, find its commands for the radio mode and the band lock in the modem's AT manual and keep the requirements: the requirements win over the old commands. These commands are dangerous, because `lw-modem-mode` sends the mode and the bands again at every start, so a wrong band lock cuts the router off again after every restart:

- before any set command, read the current value and write down the command that restores it;
- try mode and band commands from the LAN or with someone at the router, never only over the LTE link or the tunnel;
- the first image of the port goes on with `LTE_BANDS` empty (then `lw-modem-mode` leaves the bands alone) and someone at the router; lock bands only after reading and setting them by hand worked.

### 5. Wi-Fi

`zz-lw-config` takes `radio0` as 2,4 GHz and `radio1` as 5 GHz, by position. Compare with `uci show wireless` of the new router.

- Radios in another order: change the `radio0`/`radio1` lines of `zz-lw-config` and the first-boot fixtures and tests (`tests/firstboot/fixtures/etc-config/wireless`, `tests/firstboot/generic.sh`, `full.sh`, the VM overlay).
- One radio or three: the profile keys are per band (`WIFI_CHANNEL_2G`, `WIFI_HTMODE_5G`...), so the keys change too, in `render.py`, `generic.conf`, the configurator, `docs/profile.md`, `tests/configurator`, `tests/firstboot`, the VM overlay and the card text.
- A Wi-Fi 6 radio can use `HE20`/`HE80`; a new default changes in `generic.conf` and the configurator together.

### 6. Third-party packages

`modemband`, `modemdata` and their LuCI apps hold per-modem data. Check that they know the new modem (their LuCI pages on the router, and `md_serial_ecm <AT port>`, which `lw-siglog` reads), then pin the files for the new architecture in `deps.lst` (sha256, group `extra`, SPEC R2a).

### 7. The fork's own name

The GitHub build and the agent skill point at this repository, so a fork that keeps them builds MF289F images:

- `UPSTREAM` in `ci/github-run.sh` (checked by `tests/ci/30-output.sh`);
- the template repository `DamianPala/lonewrt-build`, whose workflow checks out releases of `DamianPala/lonewrt`: the fork needs its own template repository, and its name goes into `README.md`, `skills/lonewrt/SKILL.md` and `tests/skill/10-links.sh`;
- the hosted configurator address `https://damianpala.github.io/lonewrt/` in `README.md` and `SKILL.md`;
- the skill's description, which refuses routers other than the MF289F.

### 8. Recovery and documents

Rewrite the "Recovery" section of `docs/development.md` and the recovery risk in `SPEC.md` for the new router. Change the router's name in `README.md`, `SPEC.md`, `skills/lonewrt/SKILL.md`, `AGENTS.md`, `packages.md` and the card text of `src/render.py`.

### 9. Tests

The stand-ins and many tests carry the ZTE model:

- `tests/stubs/sms_tool` (the AT state model: `ZSNT`, `ZNLOCKBAND`, the SMS store), `tests/stubs/ping` (decides LTE from the `ZSNT` state) and `tests/lib.sh` (`proto`, `device`, `modes`);
- the ZTE commands and answers in `tests/modem/`, `tests/ladder/`, `tests/smoke/stubs.sh` and `tests/notify/isolation.sh`;
- the port bound in `tests/rootfs/run.sh`;
- the expectations of `tests/firstboot/generic.sh` and `full.sh` (radios, `qmi`, `/dev/cdc-wdm0`, `ttyUSB1`, `mf289f`) and their fixtures;
- `tests/vm/modem.py` and `tests/vm/overlay/` (the VM's modem, the AT port, `wwan0`, the radios);
- `tests/linkwatch/`, when QMI stays.

The rootfs tests run the image's scripts in the x86 rootfs of the same OpenWrt version, so they do not depend on the router's CPU.

## Measure again on the new router

These numbers in `SPEC.md` were measured on the MF289F and its modem firmware. They say nothing about another modem, so re-measure them with the person and write the new values with their date:

- the radio mode after an interface start and what the mode query reports (R10, R11, R28);
- the band mask and which bands the modem accepts (R12);
- `ifup wwan` to the first ping, with and without the network scan, and the start with LTE absent (R12d, D82);
- the size of the SMS store and the store it falls back to (R26, D16, Risks "Another modem firmware", the thresholds of `lw-sms-clean`);
- whether a modem reset (`AT+CFUN=1,1`, a USB unbind) restarts the whole board, and whether a router restart power-cycles the modem (D11: on the MF289F a modem reset restarts the board, so the ladder has no step between `ifup` and a reboot);
- whether the modem goes back to LTE by itself after the EDGE fallback (R22, R23, D3);
- whether a stalled modem link leaves a `NETDEV WATCHDOG` line in the kernel log (R18, class `hang` of `wwan-recover`);
- the session drop that `lw-linkwatch` repairs, when QMI stays (R49 to R49g, D80);
- the answers of `AT+CPIN?` around a missing SIM (R18).

The ladder's waits (R14a, R16, R17) are not hardware facts; keep them until a measured start time says otherwise.

## Done

- The fork's `SPEC.md` names the new router and its measurements, and part 2 says which requirements changed.
- `tests/run-all.sh`, `tests/build/run.sh`, `tests/ci/run.sh`, `tests/configurator/run.sh`, `tests/skill/run.sh` and `tests/vm/run-all.sh` pass with the new models.
- The first image goes on only after `sysupgrade -T`, a backup and the person's yes, with the recovery path known and someone at the router (AGENTS.md, `skills/lonewrt/SKILL.md`). The router then passes point 2 of Acceptance in `SPEC.md`, rewritten for the new modem's commands and device names.
