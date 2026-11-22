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
What it does not take of the router's system partition (29 MiB) holds the settings, the persistent log, the data counters and the SMS archive: about 12.5 MiB with this package set, measured on release 0.2.1.

## Changing the list

- A row starts with the package names in backticks; names in parentheses are pulled in by them and are not asked for.
- A package from the official feeds: its row here with the reason, and `PACKAGES` in `build.sh`; the full `tests/build/run.sh` fails when the two differ.
- A package from outside the feeds: also its file in the group `extra` of `deps.lst`, with its sha256.
- `tests/vm/build-image.sh` keeps its own list for the VM bench: the same without the speed test and QR packages, which no VM test uses. The same test compares it.
- When the package is a choice between ways to do something, the reason goes into a decision row of `SPEC.md` (D14, D91).
