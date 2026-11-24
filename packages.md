# lonewrt firmware: packages

The image is the official OpenWrt 25.12.6 ImageBuilder, target `ipq40xx/generic`, profile `zte_mf289f`, plus the configuration in `src/files/`.
Both tables are binding (SPEC R2): the full build test compares them with the package list of a built image.

## Included

| Package | Why | Source |
|---|---|---|
| `uqmi`, `kmod-usb-net-qmi-wwan`, `kmod-usb-serial-option`, `wpad-basic-mbedtls`, `firewall4`, `dnsmasq`, `dropbear` (with the rest of the default 25.12.6 set for the MF289F, which the device profile brings) | system, LTE over QMI, Wi-Fi; `uqmi` also serves `lw-linkwatch` (R49), and its `qmi.sh` goes into the image with one line removed (R12d) | official |
| `luci`, `luci-proto-qmi` | web panel, LTE interface in LuCI | official |
| `luci-ssl` | HTTPS in LuCI (pulls in `px5g-mbedtls` for the certificate); without it the router's https:// address does not work | official |
| `wireguard-tools`, `luci-proto-wireguard` | remote access through a WireGuard server | official |
| `tailscale`, `kmod-tun` | remote access through the owner's Tailscale account (R63, D133); only with `TS_ENABLED='1'`, so images without Tailscale keep their flash (D134) | official |
| `watchcat`, `luci-app-watchcat` | soft link repair (restarts `wwan` after `LINK_RESTART_AFTER_S`, 120 s by default) | official |
| `sms-tool` | AT commands and SMS from the console; every script of the image that talks to the modem uses it | official |
| `comgt` | required by `modemdata`, `luci-app-modemdata` and `luci-app-sms-tool-js` (apk dependency); the image does not use it directly | official |
| `luci-app-sms-tool-js` | AT commands and SMS from LuCI: on-site repair without SSH, balance queries | 4IceG (GitHub), third-party |
| `modemdata`, `luci-app-modemdata` | signal (RSRP, SNR) in LuCI; `lw-siglog` reads the signal through `modemdata` for the signal log and the bot's status | eko.one.pl feed and 4IceG (GitHub), third-party |
| `modemband`, `luci-app-modemband` | the LTE bands in LuCI: see them and lock them by hand when the modem hangs on one (D14); `LTE_BANDS` of the profile is set by `lw-modem-mode` and does not need these | eko.one.pl feed and 4IceG (GitHub), third-party |
| `wifischedule`, `luci-app-wifischedule` | Wi-Fi schedule in LuCI, off until you set one | official |
| `nlbwmon`, `luci-app-nlbwmon` | data use per device, in LuCI and in the bot's device list (R44); useful when the SIM's data plan has a cap | official |
| `speedtestcpp` (pulls in `libspeedtestcpp`, `libcurl4`, `libstdcpp6`; about 3.6 MB installed) | `/speedtest` from the bot (R41); speedtest.net client, nearest server, about 330 MB of data per test | official |
| `coreutils-timeout`, `coreutils-stty` | busybox has neither. `timeout` bounds the calls of the image's scripts that can hang. `stty` is not used by the image's scripts: `sms_tool_calllogd` of `luci-app-sms-tool-js` calls it without declaring it | official |
| `qrencode`, `libjpeg-turbo-utils` (pull in `libqrencode`, `libjpeg-turbo`; 540 KiB installed in all) | the QR photo of `/wifi` (R51, D91): `qrencode` draws the code, `cjpeg` packs it as a JPEG | official |
| `tmux` | a terminal multiplexer: an SSH session and what runs in it survive a dropped link (D167) | official |
| `mtr-nojson` | a traceroute that shows the loss of each hop, for diagnosing the LTE path; the OpenWrt build without JSON output (D167) | official |
| `vim` | a fuller editor than busybox `vi`; the small `vim` package of OpenWrt (D167) | official |
| `464xlat`, `kmod-nat46` | IPv4 for the router and the LAN devices on an IPv6-only session (R76, R76e, D169): netifd's protocol `464xlat` with its helper, and the kernel's IPv4/IPv6 translator it drives; the module loads at boot, and `lw-clat-check` makes the interface only for an IPv6-only session (R76b). The two packages are 21 327 bytes (from: `apk fetch` from the 25.12.6 feeds, 2026-11-24) | official |

## Removed from the default set

The device profile brings these packages; `build.sh` removes them (`-name` in the ImageBuilder's package list), and the manifest of a built image has none of them.

| Package | Why |
|---|---|
| `ppp`, `ppp-mod-pppoe`, `kmod-ppp`, `kmod-pppoe`, `kmod-pppox` | the LTE link is QMI, and no interface of the image uses PPP or PPPoE (D167) |

## Left out (present in eko.one.pl, not needed here)

eko.one.pl is a Polish OpenWrt site with its own builds for this router.
lonewrt was compared with its image, and this table says what that image has and this one leaves out.

| Package | Why not |
|---|---|
| `attendedsysupgrade`, `owut` | an upgrade from LuCI does not know the configuration built into the image; upgrade by rebuilding |
| `ekooneplstat`, `ekooneplmonitoring-luci`, `ekooneplconfigs` | add-ons specific to eko.one.pl; what they send is unknown; not needed |
| `collectd*`, `luci-app-statistics`, `rrdtool1`, `lm-sensors` | graphs in RAM; diagnostics come from the persistent log and the `wwan-recover` snapshot |
| `adblock`, `ddns-scripts*`, `openvpn-mbedtls`, `relayd`, `etherwake`, `luci-app-wol`, `luci-app-commands` | not used by the image |
| `luci-i18n-*-pl` | the repair instructions use the English menu names |

## Third-party packages

`modemdata` and `modemband` come from the eko.one.pl feed, the three `luci-app-*` for the modem, the bands and SMS from 4IceG's GitHub releases.
They are the only packages in the image that do not come from OpenWrt's signed feeds: `deps.lst` pins each file by sha256, and the build stops when a file differs (SPEC R2a).
[docs/network.md](docs/network.md) says what else the build downloads.

## Size

An image is about 9.9 MB.
What it does not take of the router's system partition (29 MiB) holds the settings, the persistent log, the data counters and the SMS archive: about 12.5 MiB with the package set of release 0.2.1, where it was measured; `tmux`, `mtr-nojson` and `vim` add about 0.7 MB to the root, so expect about 0.6 MiB less (estimate, D167).
An image with `TS_ENABLED='1'` has a root file system about 8 MB larger (D134), and `build.sh` stops above 15 500 000 bytes of it (R63a).

## Changing the list

- A row starts with the package names in backticks; names in parentheses are pulled in by them and are not asked for.
- A package from the official feeds: its row here with the reason, and `PACKAGES` in `build.sh`; the full `tests/build/run.sh` fails when the two differ.
- A package from outside the feeds: also its file in the group `extra` of `deps.lst`, with its sha256.
- `tests/vm/build-image.sh` keeps its own list for the VM bench: the same without the speed test, QR and power-user packages (`tmux`, `mtr-nojson`, `vim`), which no VM test uses. The same test compares it.
- A package of the device's default set that the image does not want: a row of "Removed from the default set" and `REMOVED_PACKAGES` in `build.sh`; the same test compares the two and checks the manifest.
- When the package is a choice between ways to do something, the reason goes into a decision row of `SPEC.md` (D14, D91).
