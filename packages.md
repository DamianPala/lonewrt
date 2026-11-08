# lonewrt firmware: packages

The image is the official OpenWrt 25.12.6 ImageBuilder, target `ipq40xx/generic`, profile `zte_mf289f`, plus the configuration in `src/files/`.
Compared against: `/etc/apk/world` of a clean eko.one.pl r32944 image (262 top-level packages) and `profiles.json` of 25.12.6 (38 default packages).

## Included

| Package | Why | Source |
|---|---|---|
| default 25.12.6 set for the MF289F (`uqmi`, `kmod-usb-net-qmi-wwan`, `kmod-usb-serial-option`, `wpad-basic-mbedtls`, `firewall4`, `dnsmasq`, `dropbear`...) | system, LTE over QMI, WiFi | official |
| `luci`, `luci-proto-qmi` | web panel, LTE interface in LuCI | official |
| `luci-ssl` | HTTPS in LuCI (pulls in `px5g-mbedtls` for the certificate); without it the router's https:// address does not work | official |
| `wireguard-tools`, `luci-proto-wireguard` | remote access through a WireGuard server | official |
| `watchcat`, `luci-app-watchcat` | soft link repair (`ifup` every 5 min) | official |
| `sms-tool` | AT commands and SMS from the console; all scripts of the image and the recovery use it | official |
| `comgt` | required by `modemdata`, `luci-app-modemdata` and `luci-app-sms-tool-js` (apk dependency); the image does not use it directly | official |
| `luci-app-sms-tool-js` | AT commands and SMS from LuCI: on-site repair without SSH, balance queries | 4IceG (via eko.one.pl), third-party |
| `modemdata`, `luci-app-modemdata` | signal (RSRP, SNR) in LuCI | 4IceG/obsy (eko.one.pl), third-party |
| `modemband`, `luci-app-modemband` | LTE band lock; the modem can hang on a band and stop working, and whether the router or the operator causes it is unknown | obsy (eko.one.pl), third-party |
| `wifischedule`, `luci-app-wifischedule` | WiFi schedule | official |
| `nlbwmon`, `luci-app-nlbwmon` | data use per device; useful when the SIM's data plan has a cap | official |
| `speedtestcpp` (pulls in `libspeedtestcpp`, `libcurl4`, `libstdcpp6`; about 3.6 MB installed) | `/speedtest` from the bot (R41); speedtest.net client, nearest server, about 330 MB of data per test | official (packages) |
| `coreutils-timeout`, `coreutils-stty` | busybox has neither `timeout` nor `stty`; without `stty` a raw read of the AT port falls into an echo loop | official |

## Left out (present in eko.one.pl, not needed here)

| Package | Why not |
|---|---|
| `attendedsysupgrade`, `owut` | an upgrade from LuCI does not know the configuration built into the image; upgrade by rebuilding |
| `ekooneplstat`, `ekooneplmonitoring-luci`, `ekooneplconfigs` | add-ons specific to eko.one.pl; what they send is unknown; not needed |
| `collectd*`, `luci-app-statistics`, `rrdtool1`, `lm-sensors` | graphs in RAM; diagnostics come from the persistent log and the `wwan-recover` snapshot |
| `adblock`, `ddns-scripts*`, `openvpn-mbedtls`, `relayd`, `etherwake`, `luci-app-wol`, `luci-app-commands` | not used by the image |
| `luci-i18n-*-pl` | the repair instructions use the English menu names |

## Packages from outside the official feeds

`luci-app-sms-tool-js`, `modemdata`, `modemband` and their `luci-app-*` are kept as `.apk` files in `dl/extra/` (`modemdata` and `modemband` from the eko.one.pl feed; the `luci-app-*` from the 4IceG releases).
`build.sh` copies them into the ImageBuilder's `packages/`, which accepts them.
The resulting image is about 8.9 MB and fits the flash.
