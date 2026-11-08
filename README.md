# OpenWrt firmware template for the ZTE MF289F LTE router

Builds a flashable OpenWrt 25.12.6 image for the ZTE MF289F from one profile file.
The settings live in the image, so a button reset brings the router back with the settings of its profile, not with factory defaults.
`profiles/generic.conf` is the template with no secrets; copy it, edit it, build.

What the image does and why: `SPEC.md`. Packages: `packages.md`.

Status: experimental. It runs on one router in daily use; expect rough edges on other setups.

## Hardware

- ZTE MF289F (Qualcomm ipq40xx, LTE modem over QMI, AT commands on `/dev/ttyUSB2`).
- The router must already run OpenWrt. Installing OpenWrt over the stock firmware is not covered here.
- Build host: Linux x86_64 with `bash`, `python3`, `openssl`, `curl`, `tar`, `zstd`, `make`, `flock` (util-linux), GNU awk (`gawk`; without it `fetch-deps.sh` unpacks Ubuntu's, which needs `dpkg-deb` and glibc 2.38 or newer), `bubblewrap` and `squashfs-tools` (tests only). The VM bench also needs `qemu-system-x86_64` and `/dev/kvm`.

## Quick start

```sh
./fetch-deps.sh                      # ImageBuilder, apk files, test rootfs into work/ (about 530 MB)
cp profiles/generic.conf profiles/mine.conf
$EDITOR profiles/mine.conf           # at least WIFI_COUNTRY; see "Profile keys"
./build.sh mine                      # image/mine-sysupgrade.bin, image/mine.manifest
```

Back up the router, then flash (the router must be reachable at its current address, `192.168.1.1` here):

```sh
ssh root@192.168.1.1 'sysupgrade -b -' > backup.tar.gz      # settings
scp -O -r root@192.168.1.1:/root ./router-root              # logs, SMS archive, snapshots
scp -O image/mine-sysupgrade.bin root@192.168.1.1:/tmp/fw.bin
ssh root@192.168.1.1 'sha256sum /tmp/fw.bin && sysupgrade -T /tmp/fw.bin && sysupgrade -n /tmp/fw.bin'
```

`-n` drops the overlay, including `/root/openwrt.log*`, `/root/sms-archive/` and the `wwan-recover` snapshots, hence the backup.
The router is back after about 100 s; LTE and the tunnel need about 70 s more.
The flash cuts your connection: do not run it over the router's own WiFi unless you can lose it.

An empty `WIFI_KEY` or `ROOT_PASSWORD_HASH` is drawn at random by `build.sh` and written to the password card `image/<name>-passwords.txt` (0600).
A later build of the same profile reuses the card, so the passwords do not change. Print the card or store it safely: it is the only copy.
The image keeps its profile name, build date and a hash of `src/` in `/etc/lw-build`; after a flash the same line goes to the log as `lw-firstboot`.

Other commands:

```sh
./build.sh --render-only mine /tmp/overlay   # only the rendered rootfs overlay, no ImageBuilder
./fetch-deps.sh --help                       # groups: ib extra gawk rootfs vm rescue
```

## Where things are

| Path | What | Git |
|---|---|---|
| `build.sh`, `src/render.py` | profile checks, overlay, ImageBuilder run | yes |
| `src/files/` | the files of the image (init scripts, `wwan-recover`, `lw-notify`, `uci-defaults/zz-lw-config`, cron, ...) | yes |
| `src/files/usr/share/lw/operators/` | operator presets, one data file per MCC-MNC (`29702`), see "Operator presets" | yes |
| `profiles/generic.conf` | the template profile and the list of all keys | yes |
| `profiles/<name>.conf`, `profiles/<name>/` | your profiles and their SSH key files | no |
| `image/` | build output: `<name>-sysupgrade.bin`, `.manifest`, `<name>-passwords.txt` | no |
| `work/` | ImageBuilder, downloads, VM bench (`LW_WORK` moves it) | no |
| `fetch-deps.sh`, `deps.lst` | downloads with pinned sha256 | yes |
| `tests/` | tests; reports and scratch in `tests/.out/` | yes |

## Profile keys

A profile is `profiles/<name>.conf`, lines `KEY='value'` (single quotes, no `'` inside), `#` comments. `build.sh` parses it, never sources it.
Every key of `generic.conf` must be present.
A missing key, an unknown key, an empty value where none is allowed or a malformed value stops the build with the key's name (never its value).
SSH keys go in `profiles/<name>/` as `authorized_keys`, `dropbear_ed25519_host_key` and `dropbear_rsa_host_key`, each optional.

| Key | Meaning | May be empty |
|---|---|---|
| `HOSTNAME`, `LAN_IP`, `TIMEZONE`, `ZONENAME` | name, LAN address (/24) and time zone (POSIX string and zone name) | no |
| `WIFI_SSID`, `WIFI_KEY` | one network on both bands; key 8 to 63 characters | key: drawn |
| `WIFI_COUNTRY` | two-letter regulatory country, set it before building | no |
| `WIFI_CHANNEL_2G`, `WIFI_HTMODE_2G`, `WIFI_CHANNEL_5G`, `WIFI_HTMODE_5G` | `auto` or a channel, and `HT20`, `HT40`, `VHT80`... | no |
| `ROOT_PASSWORD_HASH` | crypt(3) hash, e.g. from `openssl passwd -6` | drawn |
| `WWAN_APN`, `WWAN_AUTH`, `WWAN_USERNAME`, `WWAN_PASSWORD` | LTE access; empty APN lets the network assign one; auth is `none`, `pap`, `chap` or `both` | yes |
| `LTE_BANDS` | comma list of LTE bands to lock, e.g. `1,3,20` | yes: bands untouched |
| `WG_ENABLED` | `1` turns the WireGuard client on; needs the four keys marked below | no |
| `WG_PRIVATE_KEY`, `WG_ADDRESS`, `WG_PEER_PUBLIC_KEY`, `WG_ENDPOINT_HOST` | required when `WG_ENABLED` is `1`; `WG_ADDRESS` takes a space-separated CIDR list | yes |
| `WG_ENDPOINT_PORT`, `WG_ALLOWED_IPS`, `WG_KEEPALIVE` | the rest of the tunnel; `WG_ALLOWED_IPS` is a CIDR list | yes |
| `TG_BOT_TOKEN`, `TG_CHAT_ID` | Telegram bot (from @BotFather) and chat; both set turns on forwarding of SMS, alerts and the bot commands | yes: no notifications |
| `ROUTER_NAME` | the router's name at the start of its SMS replies (`<name>: internet OK ...`), so a reply that reaches another router running this image is not answered back: 1 to 20 ASCII characters, letters, digits, space and `-`, starting with a letter or digit, e.g. `Home 2-b` | no |
| `LOW_BALANCE` | balance threshold in the currency of the SIM's operator preset, e.g. `7.50`; turns on the weekly balance SMS and the low-balance alert (needs the bot). Used only when the SIM has an operator preset, see "Operator presets" | yes |
| `HC_PING_URL` | https ping address of a healthchecks.io check, called every 5 minutes | yes: no heartbeat |
| `SMS_ADMINS` | phone numbers that may control the router by SMS (`status`, `reboot`, `help`, any case); comma list, each `+` optional then 6 to 15 digits, no spaces, e.g. `+15550100123,15550100456`; write them in international form; a sender's national form (`0...`) still matches by its last 8+ digits | yes: no SMS control |
| `SMS_REBOOT_MAX_AGE_MIN` | an SMS `reboot` older than this many minutes (by the SMS centre time, with an NTP clock) is refused; default `10` | no |
| `SMS_REBOOT_MAX_PER_DAY` | at most this many restarts by SMS in 24 h; default `5` | no |

`WG_PRIVATE_KEY`, `TG_BOT_TOKEN`, `HC_PING_URL` and `SMS_ADMINS` are secrets or private data: they end up in the image (root-readable files), so an image built from a profile with them is private too.

## Operator presets

Everything that belongs to one mobile operator lives in a preset, a data file `src/files/usr/share/lw/operators/<MCC-MNC>` (the file name is the first 5 digits of the SIM's IMSI: the 3-digit country code and the first 2 digits of the network code, e.g. `29702`).
The service reads the IMSI from the modem (`AT+CIMI`) and loads the file of that name.
Until the modem answers, it reads the IMSI again every minute.
The preset is chosen when the service starts, so after a SIM swap restart it (`/etc/init.d/lw-notify restart`) or reboot.
Presets are in the image, so a new one needs a new build.

A SIM without a preset (no file, an unreadable IMSI, a file that does not pass the checks below) gets the safe behaviour:

- the router sends no SMS of its own except replies to an admin's command;
- `/balance` and `/status` say `Balance: not available for this operator (<MCC-MNC>)`;
- senders show as the plain number (`+` kept on long numbers);
- the weekly balance job sends nothing and the low-balance alert is off.

A rejected file leaves one line in the system log (`operator preset <MCC-MNC> rejected (<reason>)`, never a value).

### File format

Lines `KEY='value'` (single quotes, no `'` inside, no spaces around `=`), blank lines and lines starting with `#`.
The file is read as data by a strict parser and never run as a shell script, so `$(...)`, backticks, `;` and `$VAR` are rejected, not expanded.
Every key below must appear once, except `SHORT_CODES`, which may be left out.
An unknown key, a repeated key, any other line, a value with a character outside the list, or a file over 4096 bytes rejects the whole file.

| Key | Meaning | Allowed |
|---|---|---|
| `OPERATOR_NAME` | the operator's name as the chat shows it (`ask Telekom for the balance`, label `Telekom 1466`) | up to 20 of letters, digits, space, `.`, `-`; starts with a letter or digit |
| `CURRENCY` | three capital letters, shown after amounts | `EUR`, `USD`, ... |
| `BALANCE_QUERY_NUMBER` | where the balance query goes | digits with one optional leading `+`, at least 3 digits, up to 16 characters |
| `BALANCE_QUERY_TEXT` | the text of the query | up to 40 of letters, digits, space, `. , : _ -`; starts with a letter or digit |
| `BALANCE_REPLY_FROM` | the sender of the reply; a reply from any other sender is not read as a balance | up to 16 of letters, digits, space, `. + _ -` |
| `BALANCE_REPLY_PATTERN` | what the reply looks like, see below | up to 80 of letters, digits, space and `: . , ; / ( ) = + { } _ -` |
| `SHORT_CODES` | optional: senders shown as `<OPERATOR_NAME> <code>`, space separated, one code is fine | letters, digits, space, up to 120 characters |

`LOW_BALANCE` in the profile is a number in `CURRENCY`; the preset has no threshold of its own.

### The reply pattern

The pattern describes the start of the first line of the reply (the rest of the text may follow).
Plain text matches itself, a space matches any white space (also none), and these placeholders stand for parts that change:

| Placeholder | Matches | Use |
|---|---|---|
| `{amount}` | digits with an optional `.` or `,` part, e.g. `0.31`, `12,5` | exactly once |
| `{day}`, `{month}` | 1 or 2 digits | both or neither; they give "credit valid until 5 Jan" in the chat |
| `{any}` | any text | optional, as often as needed; put a fixed word between `{any}` and a number placeholder (`Stanje {any} iznosi {amount}`), otherwise the preset is rejected |

Any other brace is an error. The date is taken as day then month in the order the placeholders appear, so `{month}/{day}` works for operators that print the month first.
A reply whose sender is `BALANCE_REPLY_FROM` and whose first line fits the pattern is shown with `= Balance <amount> <CURRENCY>` (and the date when the pattern has one) and feeds `/status`, the low-balance alert and `LOW_BALANCE`.
A reply that does not fit is forwarded as a plain SMS.

### Example

```
OPERATOR_NAME='Telekom'
CURRENCY='EUR'
BALANCE_QUERY_NUMBER='1466'
BALANCE_QUERY_TEXT='RACUN'
BALANCE_REPLY_FROM='1466'
BALANCE_REPLY_PATTERN='Imate: {amount} do {day}.{month}.'
SHORT_CODES='1466 1477'
```

This is `29702` (Telekom Montenegro) and it reproduces what the router did before presets existed: `RACUN` to `1466` and a reply like `Imate: 0.31 do 05.01.`.

### Writing a preset (for a coding agent)

1. Find the SIM's MCC-MNC: the first 5 digits of the IMSI (`sms_tool`/`AT+CIMI` on the router, or the SIM's operator code from the operator's documentation). The file name is exactly these 5 digits, no extension. With a 3-digit MNC (some US networks) the file still takes only the first 5 digits, so networks that share them share the preset.
2. From the operator's documentation or a real balance SMS of the owner, take the query number and text, the sender of the reply and one example reply. Do not invent them; ask the owner if you only have a guess.
3. Turn the example reply into a pattern: keep the fixed words, replace the balance with `{amount}`, the date with `{day}` and `{month}` if it has one, anything that varies between replies with `{any}`. Keep only characters from the table; if the operator's text has others (`:` and `,` are fine, `!`, `?`, `%` and non-ASCII are not), cut the pattern before them and let `{any}` cover the rest.
4. Write the file with the keys of the table. Check by hand: no `'` inside a value, each key once, nothing but `KEY='value'` and `#` lines.
5. Test it without the router: `tests/notify/preset.sh` has a block "another operator" that writes a preset into a directory chosen with `LW_OPERATORS_DIR`, sets the fake SIM's IMSI and sends an example reply; copy it with your values and the real example reply, then run `tests/rootfs/run.sh tests/notify/<your test>.sh`.
6. Build the image. The new file is in the overlay as `/usr/share/lw/operators/<MCC-MNC>` (mode 0644).

What only the live router can show: the real reply of the operator to the query (its exact words, its sender, how long it takes). Run `/balance` once on the real SIM and check that the chat shows `= Balance ...`.

## What goes over the network

The build host downloads, through `fetch-deps.sh` and the ImageBuilder: `downloads.openwrt.org` (ImageBuilder, official packages, test rootfs, rescue image), `dl.eko.one.pl` (`modemband`, `modemdata`), `github.com` (the `luci-app-*` releases of 4IceG) and, only without a local GNU awk, `archive.ubuntu.com`.
The build sends nothing about your profile anywhere.

Besides normal routing and the OpenWrt NTP pool, the router contacts:

| Destination | When | What it receives |
|---|---|---|
| `api.telegram.org` | `TG_BOT_TOKEN` and `TG_CHAT_ID` set | the bot token (in the URL), forwarded SMS texts and senders, alerts, `/status`, `/devices` (device names, band and data used this month), `/wifi` (SSID and WiFi password) and the other command replies |
| `HC_PING_URL` | set, every 5 minutes | an empty GET |
| `8.8.8.8`, `1.1.1.1`, a DNS lookup of `openwrt.org` | always, every few minutes | pings and one DNS query, to tell whether the link works |
| the nearest speedtest.net server | `/speedtest` from the chat | test traffic, about 330 MB per run |
| `WG_ENDPOINT_HOST` | `WG_ENABLED='1'` | the WireGuard tunnel |
| the operator, by SMS | replies to `SMS_ADMINS`, the weekly balance query (with `LOW_BALANCE` and a preset), `/balance` | SMS texts; each SMS may cost money on your plan |

There is no telemetry.
The SMS replies go only to numbers in `SMS_ADMINS`; the restart by SMS has its own age and per-day limits (see "Profile keys").

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

The MF289F has no button recovery. If the system is damaged, the only way back is the serial console:
open the case, attach a UART adapter, interrupt U-Boot, load the `initramfs` image over TFTP (`./fetch-deps.sh rescue` downloads it; the laptop is `192.168.0.2`), boot it and run `sysupgrade` from there.
This is why images are flashed only after `sysupgrade -T` passes, and why the kernel is the official one.

## New OpenWrt version

1. Change the version in `build.sh` and `tests/vm/build-image.sh` (`IB_TAR`), `fetch-deps.sh` (file names in `unpack_rootfs`) and `deps.lst` (URLs and sha256 from the `sha256sums` file of each download directory).
2. Fetch the third-party `.apk` files again for that version: the feed `dl.eko.one.pl/openwrt-<release>/packages/<arch>/base/` for `modemband` and `modemdata`, the GitHub releases of 4IceG for the `luci-app-*`.
3. Compare the default configuration with what `zz-lw-config` changes (it sets only the differences).
4. Refresh the x86 rootfs for the tests.

## Maintenance, bugs, contributions

Solo project, best effort, no response-time promise.
Bug reports: open an issue with the OpenWrt version, the line of `/etc/lw-build`, what you did, what you expected and the log lines (`logread | grep lw-`); remove phone numbers, tokens, keys and addresses first.
Security problems: report them privately through "Report a vulnerability" on the repository's Security tab, not in a public issue.
Pull requests for bug fixes are welcome; open an issue first for anything larger.

Built with AI coding agents under my direction.

## Licence

MIT, see `LICENSE`. The packages the ImageBuilder puts into the image keep their own licences.
