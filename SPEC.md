# lonewrt: OpenWrt firmware template for the ZTE MF289F, spec

## Problem

An LTE router often stands where nobody is around to look after it.
The modem can hang, the data package expires, the SMS store fills up, and a button reset erases the whole configuration.
Without help this ends in long outages that the owner learns about from the people on site.
The image gives a router that comes back configured after a flash and after a button reset, repairs the usual link failures by itself and leaves a trail for diagnosis.
The same code, built from a profile without secrets, gives an image anyone with the same router model can use.

## User

- **The owner** builds the image, flashes it and manages the router remotely over a WireGuard tunnel, and optionally over Telegram and SMS.
- **People on site** use the WiFi only; when something fails they may press the reset button.
- **Someone who gets a router with the generic image** has the same router model and their own SIM; they change settings in LuCI (the router's web interface).

## Goal

The owner flashes an image built from a chosen profile onto an MF289F.
The router then comes up by itself, after the flash and after every button reset, with working LTE, WiFi and, when the profile enables it, the tunnel.
An image from a private profile is accepted by the checklist after a flash and a reset test at the router; the generic image by a trial on a router with another operator's SIM (see Acceptance).
Its usefulness shows in the first long period without a visit: did link failures end without a person.

## What it does

- **S1.** The owner builds an image from a profile; the generic image holds no secrets and no private data, and private profiles and images never reach git. When passwords are left empty, the build writes a card with the passwords and hints for the person who gets the router. (R1 to R6, R33, R33a)
- **S2.** After a flash or a button reset the router comes up with the settings of its profile, without anyone logging in. (R7 to R9)
- **S3.** At every start the router puts the modem back to LTE-only mode, the profile's bands and the right SMS store, whatever an earlier test left behind; when the profile gives no APN, the router finds one by itself. (R10 to R13)
- **S4.** When the internet goes away, the router repairs it by itself: first a restart of the connection, then restarts of the whole router at growing intervals, up to a limit. (R14 to R21)
- **S5.** When a restart does not bring LTE back, the router switches to slow 2G (EDGE) between restarts so the owner keeps remote access; after the restarts are used up it stays on EDGE and tries LTE again from time to time. (R22 to R25)
- **S6.** Operator SMS (top-ups, package expiry) keep arriving, because the router cleans the SMS store by itself and archives the whole store before it deletes anything. (R26)
- **S7.** The owner sees in the logs and in LuCI what happened: the signal every few minutes, the course of a failure, the modem state, the data usage. (R28 to R30)
- **S8.** The owner reaches the router over a WireGuard tunnel; in the generic image the tunnel is prepared but disabled. (R31 to R32)
- **S9.** With Telegram keys in the profile, every SMS on the SIM reaches the owner's Telegram chat within seconds, and once a week the router checks the balance and sends a message only when it has fallen below a threshold; from the chat the owner asks for the balance, the link state, the WiFi password, the devices and the latest SMS, runs a speed test and restarts the router. The messages are readable for a person without technical knowledge, and after a longer outage the router says the internet is back. Numbers in the profile can also ask for the state and restart the router by SMS. (R34 to R48)

## What it does not do

The image does not have these functions and does not cross these lines:

- It does not update the modem firmware.
- It does not recognise the data package, count used GB or raise an alarm during a link failure, because without internet nothing reaches Telegram; the alarm comes from a separate heartbeat on a server (R42), and the router sends a message only once the internet is back (R40).
- It changes nothing on the WireGuard server.
- It does not update itself from LuCI; a new OpenWrt version is a new image build.
- It sends no SMS other than the balance query of the operator preset (with the shipped preset `29702`: `RACUN` to 1466) and the replies to SMS commands, and no USSD codes; the bot changes no state of the router other than the 2G message switch and a restart confirmed with a button. (R27, R37a)
- The generic image holds no secrets and no data of a private profile. (R4)
- The image's scripts never talk to the modem over QMI, only with AT commands. (R12c)
- A button reset keeps no logs, snapshot, SMS archive or failure state; after a reset the link repair counts from zero. (R7b)
- It shows people on site nothing about a failure.

## How it works

**Build.** The official OpenWrt ImageBuilder puts the image together from the system packages, a few modem packages and the project's own files.
The settings of one router (address, WiFi, tunnel, passwords, notifications) live in a **profile**: a private profile may hold secrets, the generic one holds none.
Before the build a script fills the project's files with the values of the profile, so the same code gives either image.

**First start.** A flash and a button reset erase changes made on the router, but the files of the image stay.
At the first start a one-time script sets the network, WiFi, tunnel, firewall and passwords from them, so a reset brings back the configured router, not bare OpenWrt.

**Modem.** The network mode, the bands and the SMS store live in the modem's own memory, and an OpenWrt reset does not touch them.
So a start script checks and fixes them at every boot.
OpenWrt sets up the data connection over QMI (the modem control protocol), and the project's scripts use only AT commands (the modem's text commands), one at a time, under a shared lock.

**Link repair.** Watchcat, a stock OpenWrt tool, restarts the LTE connection itself, by default after 2 minutes without internet (the profile sets the wait, and always keeps it short enough for this restart to come before any restart of the whole router).
The script `wwan-recover` checks the internet every 5 minutes and, when restarting the connection does not help, restarts the whole router on a ladder of growing gaps.
It also recognises a used-up package (only the operator's DNS answers) and a SIM locked with a PIN, and then stops restarting sooner, because a restart does not help.
When a restart did not bring LTE back but the package is there, the router turns on EDGE until the next restart; a failure ends only when LTE works again.

## Example

The last line of the signal log and the end of a short failure, as the logs show them (illustrative values):

```
$ ssh root@<router> tail -n 1 /tmp/lw-signal.log
2025-01-09_12:30:03 zsnt=6 net=LTE-A_B3_(1800_MHz)_/_B1_(2100_MHz) pb=B3(1800MHz) s1=B1(2100MHz) rsrp=-85dBm rsrq=-14dB sinr=5.4dB rssi=-53dBm pci=157 loss=0% rtt=36.459 wg_age=3s
$ ssh root@<router> 'grep "wwan-recover: " /root/openwrt.log | tail -n 3'
Thu Jan  9 11:30:00 2025 daemon.notice wwan-recover: offline (tx+0 rx+0, operator DNS silent or skipped, watchdog this boot=0) cycle=3 reboots=0 class=hang mode=lte uptime=86100
Thu Jan  9 11:35:00 2025 daemon.notice wwan-recover: offline (tx+0 rx+0, operator DNS silent or skipped, watchdog this boot=0) cycle=4 reboots=0 class=hang mode=lte uptime=86400
Thu Jan  9 11:40:01 2025 daemon.notice wwan-recover: online on LTE, failure over after 4 cycles and 0 reboots cycle=4 reboots=0 class=hang mode=lte uptime=86701
```

## Key decisions

- **Configuration in the image:** a button reset brings back the configured router; in exchange, a lasting change of settings needs a new build and a flash. (D2)
- **LTE only, no automatic mode:** the router does not fall to 2G by itself and get stuck there, and with dead LTE it gets EDGE right after the first failed restart, at the cost of short breaks in access at the following restarts. This holds for the generic image too, with no switch in LuCI. (D3, D30)
- **Bands:** a profile can lock the bands that work at its site, because a modem may move from a strong band to a weak one; the generic image leaves the bands alone, because it does not know the site. (D4, D23)
- **Restart limit:** after the limit the router waits for the network or a person, instead of restarting for weeks when the package is used up. (D8)
- **Secrets in the private image:** the image is ready to flash with no further steps, but the image file and its profile must be guarded like a password and kept out of git. (D15, D20)
- **Generic image from the same code:** whoever gets it has all fixes, no secrets, a disabled tunnel and random passwords on a card handed over with the router; later images from the same profile keep those passwords. (D13, D21, D25, D36)

## Open

None.

---

Part 2 is for the maintainer and contributors.

## Requirements

### Terms

Paths starting with `/` are on the router; the others are relative to the folder of this file.

- **profile**: the file `profiles/<name>.conf` with variables and an optional folder `profiles/<name>/` with files (SSH keys); `generic.conf` holds no secrets, a private profile may. The generic image (profile `generic`, `build.sh generic`) and an image from a private profile are `sysupgrade` images built from these profiles.
- **cycle**: one run of `wwan-recover` from cron, every 5 minutes.
- **online**: an answer to a ping to 8.8.8.8 or 1.1.1.1 through the interface `wwan0` (2 packets, 3 s limit).
- **LTE-only mode** and **failure**: the router is in LTE-only mode when there is no EDGE marker in `/tmp` and `network.wwan.modes=lte`; a failure is the run of cycles from the first cycle that is not online to the first online cycle in LTE-only mode, so a cycle on EDGE belongs to the failure.
- **code** and **work folder**: `build.sh`, `src/` (scripts and templates), `profiles/` and `image/` are in this folder; the ImageBuilder and the downloaded packages are in the work folder, which `build.sh` takes from the variable `LW_WORK`, by default `work/` in this folder (ignored by git). `fetch-deps.sh` downloads everything there with pinned sha256 sums (D35).
- **limit** and **limit cycle**: the limit is the number of restarts from the limit rule (R19); the limit cycle is the first cycle that is not online after the restart that reached this number.
- **operator DNS** and **AT port**: the operator DNS is the DNS server of the `wwan` lease (with QMI it sits on the interface `wwan_4`); the AT port is `/dev/ttyUSB2` for the image's scripts and `/dev/ttyUSB1` for LuCI and manual work, both of the same modem.
- **`<r>`** and **`<ladder>`**: `<r>` is `ssh root@<router LAN address>` (the cable connection is in `README.md`); `<ladder>` is the recovery ladder tests `tests/ladder/`, run by `tests/run-all.sh ladder`.
- **`<tests>`** and **`<vm>`**: `<tests>` is `tests/run-all.sh`, which runs every test `tests/<area>/*.sh` in the official OpenWrt 25.12.6 x86_64 rootfs (the same busybox, `uci`, `jsonfilter` and coreutils `timeout` as on the router) under `bwrap`, with stand-ins for the hardware from `tests/stubs/`: an AT modem with a state model, `ping` and `nslookup` separately for LTE and EDGE, `logger`, `reboot`, `ifup`, the uptime. `<vm>` is `tests/vm/`: an image with the same files built for x86_64 and run in QEMU, with a stand-in AT modem on a serial port and a fake `wwan`. Neither of them imitates the ipq40xx hardware, QMI or the operator network.
- **operator preset**: a data file `/usr/share/lw/operators/<MCC-MNC>` with everything that belongs to one mobile operator (R47); the format is in `docs/operators.md`. The image ships `29702` (Telekom Montenegro); requirement texts quote it as the example.

### Build and profiles

- **R1:** The image is built with the official OpenWrt 25.12.6 ImageBuilder for `ipq40xx/generic`, device profile `zte_mf289f`, with the kernel and system packages of the official release (D1).
- **R2:** The image holds the packages of the "Included" table in `packages.md` and none of the "Left out" table; that table is binding (D14, D26).
  - **R2a:** The `.apk` files from outside the official feeds (group `extra` of `deps.lst`) go into the ImageBuilder only as `deps.lst` pins them: each listed file must be in `dl/extra` with its pinned sha256, checked by `build.sh` right before the copy, and `dl/extra` holds no other `.apk`. A missing, altered or unlisted file stops the build with the file's name. Before the copy, `build.sh` removes from the ImageBuilder's `packages/` the other versions of those same packages, matched by the exact package name (`modemband` is not `modemband-5g`), and nothing else; a package pinned twice in `deps.lst` stops the build with both file names (D77).
  - *scenario* given a pinned `.apk` changed by one byte, or an extra `.apk` in `dl/extra`, when the owner runs `build.sh`, then the build ends with an error naming the file, before the ImageBuilder starts
- **R3:** `build.sh <name>` builds the image from `profiles/<name>.conf`. A key of `generic.conf` missing from the profile, a key not in `generic.conf`, a key given twice, a malformed value, or an empty value of a key that may not be empty stops the build with the key's name (never its value) and no new image. Keys that may be empty: `WIFI_KEY`, `ROOT_PASSWORD` and `ROOT_PASSWORD_HASH` (R33, R33b), `WWAN_APN`, `WWAN_AUTH`, `WWAN_USERNAME`, `WWAN_PASSWORD`, `LTE_BANDS`, the `WG_*` keys except `WG_ENABLED`, `TG_BOT_TOKEN`, `TG_CHAT_ID`, `LOW_BALANCE`, `HC_PING_URL` and `SMS_ADMINS` (D20, D35, D43, D57, D61). With `WG_ENABLED='1'`, `WG_PRIVATE_KEY`, `WG_ADDRESS`, `WG_PEER_PUBLIC_KEY` and `WG_ENDPOINT_HOST` must be set. `SMS_ADMINS` outside its format (a comma list, each number with an optional `+` and 6 to 15 digits, no spaces) stops the build, and so does `LINK_RESTART_AFTER_S` outside its range (R14a).
  - *scenario* given a profile without a LAN address, when the owner runs `build.sh` with it, then the build ends with an error naming the key and there is no new file in `image/`
  - **R3a:** When the profile file holds a non-empty secret key (`WIFI_KEY`, `ROOT_PASSWORD`, `ROOT_PASSWORD_HASH`, `WWAN_PASSWORD`, `WG_PRIVATE_KEY`, `TG_BOT_TOKEN`, `HC_PING_URL`) or the profile's folder holds a private SSH host key (`dropbear_ed25519_host_key`, `dropbear_rsa_host_key`; not `authorized_keys`), and group or others can read that file, `build.sh` prints one warning that names the files and suggests `chmod 600`; the build goes on, and the warning never shows a value (D78).
- **R4:** The generic image holds no WireGuard private key, WiFi password, root password hash, SSH host keys, `authorized_keys` or bot token of a private profile (D13).
  - *scenario* given the unpacked rootfs of the generic image (`unsquashfs`), when it is searched for each value of `tests/build/fixtures/fake-full.conf` and of `tests/build/private-values.txt` (when that file exists), then there is no hit
  - **R4a:** The generic image holds no public data of a private profile either: WiFi name, WireGuard server address or tunnel address (D13).
- **R5:** Profiles other than `generic.conf`, their folders and the folder `image/` are in this folder and ignored by git (D15, D20, D35).
  - *cmd* `git check-ignore image/x.bin profiles/mine.conf profiles/mine/` prints all three paths (expected)
- **R6:** A syntax error in any script of the image stops the build before the ImageBuilder starts and leaves no partial file in `image/`.
  - *scenario* given an image script with an unclosed `if`, when the owner runs the build, then the build ends with an error naming the file and there is no new image
- **R33:** When the profile leaves the WiFi or root password empty, the build draws it, writes it into the image (the root password as a `$6$` hash from `openssl passwd -6`) and writes it in clear text to `image/<name>-passwords.txt` (mode 0600) in the lines `ssid=`, `wifi=` and `root=`; when that file already exists, the build takes the passwords from it instead of drawing new ones (D21, D36).
  - *scenario* given `generic.conf` with empty passwords, when the owner builds the image twice, then `image/generic-passwords.txt` has the WiFi name and two passwords, the second build does not change it, and after flashing either image both passwords work
  - **R33b:** The root password can also be given in clear text as `ROOT_PASSWORD` (8 to 63 printable ASCII characters, as `WIFI_KEY`); the build hashes it the way it hashes a drawn one and writes only the hash into the image. Exactly one of `ROOT_PASSWORD` and `ROOT_PASSWORD_HASH` may be set: both set stops the build with an error naming the two keys; both empty keeps R33. When a card for the profile already exists, every build rewrites it from what the image holds, so it never names a password the image does not have: drawn values keep coming from the old card, a value the profile sets replaces the card's (`wifi=`, and `root=` with the profile's `ROOT_PASSWORD`), and for a profile that gives only `ROOT_PASSWORD_HASH` the card has no `root=` line and says that root uses the hash from the profile. When no card exists and nothing is drawn, no card is written. A rebuild keeps the password, not the hash: the hash gets a new salt each time, as for a drawn password. An image from a profile with `ROOT_PASSWORD` is private by the rule that holds for `ROOT_PASSWORD_HASH` (R4, D15). Neither the build output nor the image holds the clear text (D73).
  - *scenario* given a profile with `ROOT_PASSWORD='fake-root-pw-q7x9'`, when the owner builds the image, then the root password on the router is that password, and neither the build output nor the overlay holds it in clear text
  - **R33a:** The same file has hints below the passwords for the person who gets the router (in English): the LuCI address over HTTPS and the browser's certificate warning; that a button reset brings back the passwords of the card; that a SIM with a PIN needs the PIN removed or entered in LuCI; that without internet 5 minutes after the start the APN is entered in LuCI; that the LTE-only mode cannot be changed in LuCI; that the router restarts itself on a failure, and how to turn that off in LuCI's scheduled tasks; that above 30 SMS the router archives the whole store to `/root/sms-archive/` daily at 04:10 and deletes the oldest down to 20; and that the WiFi country is changed in LuCI (D36).

### First start and reset

- **R7:** After a flash with `sysupgrade -n` and after a button reset, at its first start the image sets everything in the column "From the profile" of the table below; the table is binding (D2).
  - **R7a:** After the same flash or reset, the generic image ends with the values in the column "With `generic.conf`" (D21, D25).
    - *scenario* given the generic image from `generic.conf`, when the router comes up after the flash, then the LAN has `192.168.1.1`, the WiFi is called `OpenWrt-LTE` with the password from `image/generic-passwords.txt`, and `wg0` is disabled

| Setting | From the profile | With `generic.conf` |
|---|---|---|
| LAN | `LAN_IP`, mask /24 | `192.168.1.1/24` |
| WiFi | both bands, one name and password (`WIFI_SSID`, `WIFI_KEY`), `psk2` (WPA2 only, D74), 802.11r fast roaming, country, channels and HT modes from the profile | as from the profile: name `OpenWrt-LTE`, password drawn, country `PL`, which the owner changes to the router's country before the build |
| WiFi schedule | installed, off | the same |
| LTE | interface `wwan` over QMI, APN from the profile by the APN rule (R13), mode by the LTE-only rule (R10) | the same, with an empty APN and the operator table as fallback (R13a, R13b) |
| WireGuard | `wg0` and zone `vpn` always exist; with `WG_ENABLED='1'` the tunnel is on by the tunnel rule (R31), otherwise off by the generic tunnel rule (R32) | tunnel off (R32) |
| firewall | `wwan` in zone `wan`, `wg0` in zone `vpn` | the same |
| system | host name `HOSTNAME`, time zone `TIMEZONE` and `ZONENAME`, persistent log by the log rule (R29) | the same, host name `lte-router` |
| root password | hash `ROOT_PASSWORD_HASH`, the hash of `ROOT_PASSWORD` (R33b), or drawn (R33) | drawn |
| SSH | host keys and `authorized_keys` from `profiles/<name>/` when present, the same after every reset; missing host keys are generated at the first start | host keys generated at the first start, no `authorized_keys` |
| watchcat | restart of the interface `wwan` after `LINK_RESTART_AFTER_S` seconds without a ping answer (R14, R14a) | after 120 s |
| cron | `wwan-recover` every 5 min, `lw-siglog` every 5 min shifted by 2 min, `lw-sms-clean` at 04:10; `lw-notify balance` (the preset's balance query) on Monday at 10:00 by the balance rule (R35) when `TG_BOT_TOKEN`, `TG_CHAT_ID` and `LOW_BALANCE` are set; `lw-heartbeat` every 5 min when `HC_PING_URL` is set (R42) | the first three only |
| notifications | service `lw-notify` with token, chat, threshold, router name and SMS admins from the profile (R34 to R38, R46) | none, keys empty |

- **R7b:** The image has a file `/etc/lw-build` with the profile name, the build date and a hash of the files in `src/`, and the first start, once syslog and the persistent log (R29) run, writes an entry with the tag `lw-firstboot` with the same content, so after a reset the log shows that there was a reset and which image runs (D37).
- **R8:** The first start does not wait for the modem: LAN, WiFi and SSH come up even when the modem does not answer.
  - **R8a:** A first start cut by a power loss finishes the configuration at the next start, with the same result.
- **R9:** Changes made in LuCI survive a restart; the exceptions are the LTE mode and the bands, which the modem state rule puts back (R10, R11).

### Modem

- **R10:** At every start, before LTE first comes up, the interface `wwan` asks for LTE-only mode (`network.wwan.modes=lte`), also after the EDGE fallback (D3).
- **R11:** At every start, in the background and not earlier than one minute after the AT port appears, the router brings the modem to this state: LTE-only mode (`+ZSNT: 6,0,0`), the bands of the profile, SMS store `ME` for reading, writing and receiving (D3).
  - *scenario* given a profile with `LTE_BANDS='1,3,8,20,28,32'` and a modem left in auto mode with other bands by a test, when the router restarts, then within 5 min `AT+ZSNT?` gives `6,0,0`, `AT+ZNLOCKBAND?` gives the mask `88080085`, and syslog has an `lw-modem-mode` entry with `modem OK`
  - **R11a:** When the mode and bands already match, the modem gets no command to change the mode or bands; the SMS store command goes at every attempt.
  - **R11b:** When the state still differs after 3 attempts 30 s apart, or the AT port does not appear within 120 s, the router writes that to syslog (tag `lw-modem-mode`) and does nothing more until the next start.
  - **R11c:** A profile with `LTE_BANDS` locks the modem to those bands (D4); a profile without bands does not change the modem's bands (D23).
- **R12:** The image's scripts send AT commands only through `/dev/ttyUSB2`, including when reading and setting the bands and when reading the IMSI (D28). The bands are set with `AT+ZNLOCKBAND=1,0,<mask>,0` and read with `AT+ZNLOCKBAND?`, where bit n-1 of the hexadecimal mask is band n; for example bands 1, 3, 8, 20, 28, 32 give `88080085`.
  - **R12a:** The image's scripts send at most one AT command at a time on `/dev/ttyUSB2`, because they all take the shared lock `/tmp/lw-at.lock`; LuCI on `/dev/ttyUSB1` works without this lock (D5).
  - **R12b:** Every AT command, the wait for the lock included, has a time limit of 10 to 30 s, and at most 20 s in the APN script; when the limit runs out, no process of that command is left (D29).
    - *cmd* on the router: with the lock held by `flock /tmp/lw-at.lock sleep 60 &`, a read of `AT+ZSNT?` in the image's form with a 20 s limit ends after about 20 s with exit code 124, and `ps` shows no orphan (expected)
  - **R12c:** No script of the image runs `uqmi`; QMI serves only netifd for the data connection (D5).
    - *cmd* `rg -n '^[^#]*\buqmi\b' src/files/` finds nothing (expected)
- **R13:** An APN given in the profile or entered in LuCI is used unchanged and never overwritten (D27).
  - **R13a:** When no APN is given (the generic image), the router connects with an empty APN and the network assigns its own; syslog has an `Auto-APN` entry that the empty APN works (D27).
  - **R13b:** At every failed connection attempt (`ifup-failed`) from the second in a row, when the APN is empty or carries the "from table" marker, the router reads the SIM's IMSI, writes APN, authentication and login from the operator table (26001, 26002, 26003, 26006, 29701, 29702 and 29703) with the "from table" marker, and reconnects at once; an unknown operator stays with the empty APN, and syslog has an `Auto-APN` entry with the MCC-MNC and a note that the APN must be entered in LuCI (D27, D34).
    - *scenario* given the generic image and a SIM of an operator from the table whose network rejects an empty APN, when two attempts in a row fail, then the third attempt goes with the APN from the table, and syslog has an `Auto-APN` entry with the operator's name
  - **R13d:** The "from table" marker remembers the APN it wrote and holds only while the current APN equals it, so an APN changed in LuCI falls under the profile APN rule (R13); the router replaces a marked APN with the table APN of a new SIM when, at a failed attempt, the IMSI points to another operator. The APN script never holds up other hotplug events, because it runs in the background, and at most one copy of it runs (D34).
  - **R13c:** When `AT+CPIN?` does not give `READY`, or the IMSI cannot be read in 6 tries, the settings stay as they are and syslog has an entry with the tag `Auto-APN`; an attempt cut by a busy lock is not repeated in that run, because the next failed connection attempt starts the script again, and the whole APN script ends within 150 s (D29).

### Link repair

- **R14:** When no ping to 8.8.8.8 or 1.1.1.1 (sent every 60 s) gets through for `LINK_RESTART_AFTER_S` seconds, 120 s by default, watchcat restarts the interface `wwan`, and does so again after every such period of silence, even after the restart limit (D6, D79).
  - **R14a:** `LINK_RESTART_AFTER_S` is a key of every profile: a whole number of seconds from 120 to 900, written as the `period` of the watchcat entry `wwan_soft`; nothing else of that entry (mode, interface, hosts, ping period of 60 s) depends on the profile. A value outside the range, not a number or empty stops the build with the key's name and the range (R3). The lower bound is two ping periods, so a restart needs at least two pings in a row without an answer. The upper bound keeps the interface restart ahead of the first router restart of `wwan-recover` (R16), which comes at the 6th cycle of a failure, in two cases. (a) Steady state: the drop is at D and the router has been up for more than 10 min (R17). The first failed cycle is in [D, D+300), so the 6th cycle is at D+1500 at the earliest. Watchcat restarts the interface about `60 * ceil(period / 60) + 20` s after its last answer (the checks run every 60 s, a failed ping waits 10 s per host), so with 900 s it comes by D+920 at the latest, and the link is back about 40 s later, by D+960. (b) A failure already there at boot: watchcat waits until uptime `period` before it counts, so with 900 s its first restart is at about 1820 s of uptime and the link is back at about 1860 s. `wwan-recover` starts a failure only from uptime 600 (R17), so its first cycle is in [600, 900) and its 6th cycle, the router restart, is at 2100 s at the earliest. With 900 s the interface restart comes first in both cases, with 540 s to spare in (a) and 240 s in (b) (D79). The order "interface restart, then router restart" of part 1 and of R16 therefore holds for every value in the range.
    - *cmd* `tests/build/10-profile.sh` expects 120 and every value in range as the `period` of `wwan_soft` in the rendered `etc/config/watchcat`, and a stop naming the key and the range for 0, 119, 901, a leading zero, a sign, a fraction, text, a space, fullwidth digits and an empty value (expected)
    - *cmd* `tests/firstboot/generic.sh` and `tests/firstboot/full.sh` expect `watchcat.wwan_soft.period` 120 and 180 after the first start (expected)
    - *scenario* given the generic image, when the data session is dropped by the operator while the modem stays registered, then watchcat restarts `wwan` about 80 to 140 s later (the 2nd failed ping 60 s after the 1st, each waiting 10 s per host) and the link is back about 40 s after that, with no router restart
- **R15:** An online cycle in LTE-only mode ends the failure and resets its counter (in the LTE probe after the limit only with the mode confirmed, R23), and the first cycle that is not online starts a failure (D6, D30).
- **R16:** During a failure the router restarts after 6, 18, 42, 90, 162 and 234 cycles from its start, that is after about 30 min, 1.5 h, 3.5 h, 7.5 h, 13.5 h and 19.5 h, even when it is on EDGE (D7, D11, D30).
  - *cmd* `tests/ladder/hang.sh` (modem hang, 250 cycles) expects `REBOOT` entries at cycles 6, 18, 42, 90, 162, 234 (expected)
  - *cmd* `tests/ladder/edge-works.sh` (dead LTE, working EDGE) expects the same restarts and an `EDGE enter` entry in the first cycle after the boot grace after every restart (expected)
  - **R16a:** The restart happens in the first cycle in which the failure counter reached or passed the threshold, even when the threshold cycle was skipped (the first 10 min after a start, the lock).
- **R17:** In the first 10 min after a start `wwan-recover` keeps counting the cycles of an ongoing failure, but does not start a new failure, give a class, take a snapshot, switch to EDGE or restart the router.
- **R18:** Only a cycle that is not online and is in LTE-only mode gets a class, checked in this order: `sim` when `AT+CPIN?` answers about the SIM with something other than `READY` or `SIM busy` (no answer, a bare `ERROR` and a short `SIM busy` after a modem reset are not `sim`); `account` when no new `NETDEV WATCHDOG` entry appeared in the log during this boot and the operator DNS answers; `hang` when a watchdog entry appeared or fewer than 2 packets went out in the cycle, the pings of this cycle included; otherwise `unknown`, treated as `hang`. `sim` and `account`, once given, stay until the end of the failure, because watchcat bringing `wwan` up and a briefly silent port give false `hang` in single cycles. Cycles on EDGE do not change the class (D31, D38, D40).
  - **R18a:** The class never holds a restart back before the limit (D10).
  - **R18b:** The last class from a cycle in LTE-only mode, also from a cycle of the LTE probe after the limit (R23), is saved in the failure state as the limit class, and it decides about EDGE after the limit and after a restart (D31, D41).
  - **R18c:** The operator DNS answers when `timeout 5 nslookup <fixed name> <DNS of the wwan lease>` ends with exit code 0; no DNS in the lease means no answer, and the number of sent packets is measured before this query (D31).
  - **R18d:** The class `sim` acts in the limit and EDGE rules like `account` (R19, R22, R22a, R25), and its syslog entry gives the answer of `AT+CPIN?` and says that the PIN is entered in LuCI (D38).
  - **R18e:** A `NETDEV WATCHDOG` entry (R18, R21d) is a line of the kernel, in the persistent log and in `logread` alike: after the 24-character date the facility `kern`, then `kernel:` and the words. The same words in a line of a service (a failed login with a chosen user name, for example) do not count, so a LAN user cannot turn the class `account` into `hang`.
    - *cmd* `tests/ladder/classes.sh` with lines of `daemon`, `authpriv` and `user` that hold the words, and with the whole kernel prefix inside the message of a service, expects the class `account` (expected)
- **R19:** After 6 restarts in one failure (2 when the last class is `account` or `sim`) the router goes into passive mode: it does not restart until it is online again in LTE-only mode, and syslog has an entry with `LIMIT:` (D8).
  - *cmd* `tests/ladder/account.sh` (pings fail, operator DNS answers, traffic goes out) expects restarts only at cycles 6 and 18, no `EDGE` entry and class `account` in the state; `tests/ladder/no-dns.sh` (DNS silent too) expects the full ladder and EDGE (expected)
- **R20:** A diagnostic snapshot (traffic counters, address, modem readings over AT, latest watchdogs) goes to `/root/wwan-recover-snapshot.txt` at the start of a failure as a new file (the previous one becomes `.old`), and is appended to before every restart and at the limit; every entry has a header with the reason, the cycle and the uptime, and the last 12 lines of the signal log.
  - **R20a:** The modem readings in the snapshot take at most 30 s together: with a busy AT lock or after the first command that ran out of time, the snapshot skips the remaining readings and records that (D33).
    - *scenario* given the AT lock held by `flock /tmp/lw-at.lock sleep 600 &`, or an `sms_tool` that does not answer, when a cycle reaches a restart threshold, then the restart happens within 30 s and the snapshot has an entry about the skipped readings
- **R21:** The failure counter survives a router restart and counts cycles, not time (D9).
  - **R21a:** A second run while the first is still running ends at once; the next cycle takes over the lock of a process that is gone or has run for more than 20 min, first ending that process with its children, and every run ends after 270 s at the latest (D22).
    - *scenario* given a `wwan-recover` lock left by a process killed with `kill -9`, when the next cycle starts, then the cycle takes over the lock and works normally
  - **R21c:** An interrupted write of the failure state leaves no damaged file: the state is either the old or the new one; the state is written only when something other than the uptime changed in it.
  - **R21d:** The failure state is in `/etc/wwan-recover.state` as `key=value` lines with at least the cycle count, the restart count, the limit class, passive mode and the uptime at the write; the reference for new `NETDEV WATCHDOG` entries counts from the current boot, because after a restart the RAM log starts from zero (D39).
  - **R21e:** Every `wwan-recover` entry in syslog ends with the fields `cycle= reboots= class= mode= uptime=`, where `mode` is `lte` in LTE-only mode (also in the LTE probe after the limit) or `edge`, because during a failure the router's clock may have gone back (D9, D39).
  - **R21b:** With `DRYRUN=1` the script changes nothing (no restart, no state write, no EDGE), and every one of its syslog entries has the prefix `[DRY-RUN]`.

### EDGE fallback

The fallback puts the modem into automatic mode; on networks that run only 2G next to LTE, this means EDGE.

- **R22:** When the failure state has at least one restart from the ladder and is not passive, 10 min have passed since the start, the router is not online and the last class is not `account` or `sim`, the router switches the modem to automatic mode (`network.wwan.modes=all` and `AT+ZSNT=0,0,0`) and brings `wwan` up again, at most once per start. In the cycle in which the failure reaches the limit, the router first settles the limit (R19), then the switch to EDGE by the passive mode rule (R22a) (D30).
  - *scenario* given dead LTE (ping and operator DNS silent) and ping and operator DNS working on EDGE, when 250 cycles pass, then there are 6 restarts, the saved limit class is `hang`, and the router stays on EDGE
  - **R22a:** In passive mode, from the limit cycle on and after every start, the router switches to EDGE when 10 min have passed since the start and it is not online, at most once per start, not counting the return after a failed LTE probe (R23), unless the saved limit class is `account` or `sim` (D32).
    - *scenario* given a failure state after the limit with class `hang` and a fresh start of the router, when 10 min pass without being online, then the router switches to EDGE exactly once
- **R23:** Before the limit, EDGE lasts until the next restart from the ladder. After the limit the router, every 72 cycles on EDGE, online or not (6 h), tries LTE-only mode: it removes the EDGE marker, sets `network.wwan.modes=lte` and `AT+ZSNT=6,0,0` and brings `wwan` up, so the probe cycles are cycles in LTE-only mode. An online probe cycle ends the failure when a read of `AT+ZSNT?` confirms LTE-only mode; 2 probe cycles that are not online or lack this confirmation go back to EDGE, unless the class from the probe is `account` or `sim` (D30, D41).
  - **R23a:** After the limit the router on EDGE does not restart, even when EDGE goes away (D30).
    - *scenario* given the router on EDGE after the limit, when there is no online cycle for 100 cycles, then there is no restart
- **R24:** A router restart always ends the EDGE fallback, and the router comes up in LTE-only mode by the modem state rules (R10, R11); it goes back to EDGE only by the EDGE rules (R22, R22a) (D12).
- **R25:** When the saved limit class is `account`, the router never switches to EDGE, even after a restart; when the package runs out while the router is already on EDGE, the router leaves EDGE at the next restart from the ladder (D24).

### SMS store

The `ME` store of the modem holds 50 messages, and a full store blocks delivery until the modem registers with the network again (measured on the modem firmware named in Risks).

- **R26:** Every day at 04:10, when the `ME` store holds more than 30 messages, the router saves the whole store as JSON from `sms_tool` to `/root/sms-archive/<YYYYMMDD-hhmmss>.json` and deletes the oldest messages until 20 are left; with 30 or fewer it neither archives nor deletes anything (D16).
  - **R26a:** The age of a message comes from its time stamp, and a message without a time stamp counts as the oldest.
  - **R26b:** The archive keeps the 20 latest dumps.
  - **R26c:** When the modem does not answer, the router deletes nothing and writes a syslog entry (tag `lw-sms-clean`).
  - **R26d:** With `DRYRUN=1` the script prints the number of messages and the indices it would delete with the thresholds `MAX` and `KEEP` from the environment, and neither deletes nor archives anything.
  - **R26e:** An interruption during deleting leaves the archive of the whole store from before deleting, and the next run works by the thresholds of the cleaning rule (R26).
  - **R26f:** The cleaning reads the list with the repair of the sender field of R34h, so a message with a quote or a backslash in its sender does not stop it, and the dump holds the repaired list; a list that stays unreadable deletes and archives nothing, with the syslog entry of R26c.
- **R27:** By itself the image sends only the balance query of the operator preset (R47; with the preset `29702` the SMS `RACUN` to 1466), by the balance and bot command rules (R35, R37), and replies to SMS commands from the numbers in `SMS_ADMINS` (R46); it never sends other SMS or USSD codes (D47, D61).
  - *cmd* `rg -n 'sms_tool[^|;]* (send|ussd)|AT\+CMGS|AT\+CUSD' src/files/` finds only the one send function of the notification scripts, which carries the balance query and the SMS replies (expected)

### Diagnostics and LuCI

- **R28:** Every 5 min the router appends to `/tmp/lw-signal.log` one line with the fields `zsnt net pb s1 rsrp rsrq sinr rssi pci loss rtt wg_age` in the order and format of the Example (D17).
  - *cmd* `<r> tail -n 1 /tmp/lw-signal.log` gives one line in the format of the Example (expected)
  - **R28a:** The log keeps the last 5 000 lines, in RAM only, and is gone after a restart.
  - **R28b:** The line is written even without internet or an answer from the modem (a field without a reading is `?`), and a run ends within 240 s, before the next one.
- **R29:** Syslog also goes to `/root/openwrt.log` (1 MB, then the file `.old`) and survives a restart.
  - **R29a:** Cron does not log the start of every job.
  - **R29b:** The syslog entries of the image's scripts, the snapshot, the state file and the signal log are in English and in ASCII (D42).
- **R30:** LuCI runs over HTTPS, and plain HTTP on port 80 only redirects to it (`uhttpd.main.redirect_https=1`, set at the first start when the section exists) (D19).
  - **R30a:** LuCI shows the signal (modemdata, over AT on `/dev/ttyUSB1`), the bands (modemband), SMS and AT (sms-tool), data usage per device (nlbwmon, with its database on flash by R44a), watchcat and the WiFi schedule (D14, D26).

### Remote access

The image does not change the server; these rules apply to the router only.

- **R31:** With `WG_ENABLED='1'` the image connects `wg0` to the server of the profile, with the profile's keepalive (`WG_KEEPALIVE`) (D2).
  - **R31a:** The router and the LAN are reachable from the tunnel, and nothing passes from the LAN into the tunnel (D2).
- **R32:** The generic image has `wg0` and the zone `vpn` like any other image, but the interface is disabled and has no key, peer or endpoint; turning it on means entering them in LuCI (D25).
  - *scenario* given a router with the generic image, when the owner enters key, peer and endpoint in LuCI and enables `wg0`, then the tunnel comes up and still works after a restart

### Notifications (Telegram)

They work only when the profile sets `TG_BOT_TOKEN` and `TG_CHAT_ID`; without them the image runs no part of this section except SMS control (R46d) (D43).
Some operators send no SMS when data runs low and renew a package only with enough credit on the account; the balance rules cover that.

- **R34:** Every new SMS in the modem store reaches the chat `TG_CHAT_ID` as a message with the sender, the modem's time and the full text, within 30 s of appearing in the store when the router has internet; the exception is balance replies, which follow the balance rule (R36) (D43, D46).
  - **R34a:** An SMS that could not be sent waits and goes out within 30 s of the internet coming back, even after a router restart; every SMS reaches the chat at most once, even after a restart.
  - **R34b:** Checking the store every 15 s takes the AT lock (R12a) for at most one short command; with a busy lock the pass is skipped instead of waiting.
  - **R34c:** A normal pass writes nothing to syslog or flash; flash is written only for a new SMS or a sent message, and syslog gets at most one entry per change of the sending state (works or does not work), with the tag `lw-notify`.
  - **R34d:** The bot token does not appear in syslog, the signal log, the snapshot or the bot's replies.
  - **R34e:** Latin-1 characters (such as `é`, `ü`) that `sms_tool` returns as single bytes instead of UTF-8 reach the chat as the same characters; Telegram rejects such a raw byte with `HTTP error 400`.
  - **R34f:** A message Telegram rejects (HTTP 400) does not block the queue: it goes once more with the text reduced to ASCII, and when that is rejected too, it leaves the queue with one `lw-notify` syslog entry; the following messages go on. A rejection is not reported as a lost link (R34c).
  - *scenario* given an SMS with the byte `E9` in its text and a second SMS after it, when the router has internet, then the chat has both, the first with `é`, in the order they arrived
  - **R34g:** A long SMS arrives in parts, and `sms_tool` gives `reference`, `part` and `total` for each. The parts of one message (same sender and `reference`, 2 to 20 parts) go to the chat as one message, joined without a separator in the order of `part`, once all are there. When a part is still missing 10 min after the first part, what is there goes out with the note `(part <n> of <total> missing)`. `/sms` shows and counts the joined messages. SMS commands (R46) in a message of several parts are not run (D67).
  - *scenario* given an SMS in 2 parts, with part 2 before part 1 in the store, when both are in the store, then the chat has one message: the text of part 1 followed by the text of part 2
  - **R34h:** `sms_tool` prints the sender of a message as the network gave it, without escaping `"` and `\`, and a text sender ID may hold both, so one such message makes the whole list invalid JSON. Before the list is read, these two characters are escaped in the sender field (only there, and only when the list cannot be read as it is; a valid list is read unchanged), and the message is forwarded like any other; `/sms` and the cleaning of the store (R26f) read the same repaired list. When `sms_tool` answers with exit code 0 but the list is still unreadable on 3 reads in a row, syslog gets one `lw-notify` entry and the chat one message, `⚠️ One SMS in the modem cannot be read.` with the words that new SMS are not posted and SMS commands do not work until it is deleted, and where to delete it (LuCI: Modem, SMS) (R39); once per occurrence, the next only after the list was readable in between. Until then SMS are not forwarded and SMS commands do not run (D71).
    - *scenario* given a store with a message whose sender is `AB"CD`, when the router reads the list, then the chat has that message with the sender `AB"CD`; given a store entry that is cut off, when 3 reads in a row fail, then syslog and the chat get one report, and after the entry is deleted the SMS that waited come once
  - **R34i:** What `lw-notify` and `lw-sms-clean` create (the queue and the other state on flash and in RAM, the request bodies, the SMS dumps) is readable by root only (files 0600, directories 0700); only root processes (the service, cron, hotplug) use them.
  - *scenario* given a router with internet, when an SMS arrives on the SIM, then within 30 s the chat has a message with its sender and text, and after a router restart this message does not come a second time
  - *scenario* given a router without internet, when 2 SMS arrive, then the router restarts and the internet comes back, then both reach the chat, each once
- **R35:** Once a week, on Monday at 10:00, the router sends the preset's balance query (`RACUN` to 1466 with `29702`) (D44, D47).
- **R36:** A balance reply (from the preset's `BALANCE_REPLY_FROM`, first line fitting `BALANCE_REPLY_PATTERN`; with `29702`: from 1466, `Imate: <amount> do <date>`) counts as one while the router waits for an answer: it sent the balance query (R35, `/balance`) less than 10 min ago. Every matching reply in that window counts and runs the rule below; an answer does not end the window. Any other message that fits is an ordinary SMS (R34): it reaches the chat as it is, without the translation of R39b and the warning, and changes neither the last known balance nor the memory below (D72). The one exception is the first scan after a flash or a reset (no list of handled SMS yet, as in R46e), which only records the store and forwards nothing: there a message fitting the pattern sets the last known balance without a query, so `/status` has a balance right after a flash (D72); after a restart a message that came meanwhile is judged like any new one. A balance reply reaches the chat only when it answers a `/balance` command from the last 10 min, or when the amount is lower than `LOW_BALANCE` and the previous amount read was not lower; an amount equal to or above the threshold only clears that memory, with no message. The low-balance message adds a note with the threshold. An empty `LOW_BALANCE` turns off the weekly query (D44).
  - *scenario* given the threshold 7.50, when the weekly replies are 8.00, 0.32, 0.32, 9.00, 0.50 in turn, then only 0.32 (the first) and 0.50 reach the chat, both with the threshold note
  - *scenario* given the threshold 7.50 and no query of the router in the last 10 min, when an SMS from 1466 says `Imate: 99.00 do 01.02.;`, then the chat has it as an ordinary SMS and `/status` still shows the balance read before
  - *scenario* given the threshold 7.50, the weekly query and a forged `Imate: 99.00 do 01.02.;` at 10:00:05, when the real `Imate: 0.31 do 05.01.;` comes at 10:00:20, then the chat has the low-balance warning and `/status` shows 0.31; given the real 0.31 first and the forged 99.00 after it inside the 10 min, then the warning has been sent and `/status` shows 99.00 (accepted, D72)
  - *scenario* given `/balance` and two replies inside the 10 min, 12.40 and then 12.50, when both arrive, then the chat has the balance message for the first and nothing for the second (the answer ends the request of `/balance`), and `/status` shows 12.50
- **R37:** The router answers commands from the chat `TG_CHAT_ID` within 30 s, in English; it ignores messages from other chats without replying, and does not run commands sent before it started (D45, D48).
  - **R37b:** `TG_CHAT_ID` may be a group: every member can use the commands, a command also works with the bot's name appended (`/status@<bot>`), and the bot ignores messages without a command; when Telegram reports that the group moved to a new ID, syslog gets one `lw-notify` entry with the new ID (D48).
  - `/balance`: sends the preset's balance query and passes on the reply by the balance rule (R36); a second `/balance` while a query waits less than 2 min gets a "still waiting" message; when the reply does not come within 2 min, the chat is told that there is no answer yet.
  - `/status`: the router state by R39c.
  - `/sms [n]`: the n newest SMS in the store (5 by default, at most 10).
  - `/help` and `/start`: the list of commands; every unknown command gets the same list.
  - `/alerts`: shows which automatic messages are on; `/alerts 2g off` and `/alerts 2g on` turn the 2G message (R40c) off and on, and the answer confirms the new state (R37c).
  - `/speedtest`: speed test by R41.
  - `/wifi`, `/devices`, `/reboot`: by R43, R44 and R45.
  - **R37a:** The bot has no command that changes the state of the router or the modem, except sending the balance query, the 2G message switch (R37c) and a restart confirmed with a button (R45); `/speedtest` uses data but changes nothing (D45, D53, D54, D60).
  - **R37c:** The 2G message switch survives a router restart, and a button reset or a new flash set it back to `on`; flash is written only on a change (D53).
- **R38:** The notifications run as one procd service that comes up at the start and after a crash of its process; a run against a network that does not answer ends within its time limit and leaves no process (D46).
  - **R38a:** A profile without `TG_BOT_TOKEN` or without `TG_CHAT_ID` gives an image that works as if this section did not exist: no Telegram part runs, cron does not ask for the balance, and the remaining requirements pass unchanged; without `SMS_ADMINS` as well, the service does not start and nothing reads the store every 15 s. When only one of the two Telegram keys is given, the first start writes one `lw-notify` syslog entry that notifications are off (D43).
  - **R38b:** No failure of the notifications (wrong token, Telegram unreachable, script error, killed process) restarts the router, changes the modem mode or `wwan`, or delays other scripts by more than one short AT command (R34b).
  - *scenario* given an image from a profile without Telegram keys and without `SMS_ADMINS`, when the router runs for a day, then there is no `lw-notify` process, the crontab has no `lw-notify balance`, and first start, modem, link repair and log work as in an image without this section
- **R47:** The router picks the **operator preset** by the first 5 digits of the SIM's IMSI (MCC-MNC) whenever the notification service starts; until the modem answers, it reads the IMSI again every minute. A preset is a `KEY='value'` file in the image, read as data and never run. It gives the operator's name, the number and text of the balance query, the pattern of the reply with amount and date, the short codes to label and the currency. The balance requirements (R35, R36, `/balance` in R37, R39a, R39b, the balance lines in `/status` and in the `status` SMS reply) work by the preset. Their texts quote the shipped preset `29702` (Telekom Montenegro): `RACUN` to 1466, reply `Imate: <amount> do <date>`, short codes 1466 and 1477, EUR (D66).
  - **R47a:** Without a preset for the SIM, the router sends no SMS except the replies of R46. `/status` then has the line `💶 Balance: not available for this operator (<MCC-MNC>)`, and `/balance` answers the same. Senders get only the `+` of R39a, no labels. The weekly query (R35) sends nothing.
    - *scenario* given the generic image with a SIM `26003`, when `/balance` comes, then the bot answers `💶 Balance: not available for this operator (26003)` and the modem sends no SMS
  - **R47b:** `LOW_BALANCE` is a threshold in the preset's currency, and balance messages show the preset's currency. `docs/operators.md` describes the preset format with the example `29702`, so a preset for another operator can be added without code changes.
  - **R47c:** The reply pattern is plain text, a space for any white space (also none), and the placeholders `{amount}` (once), `{day}` with `{month}` (both or neither) and `{any}` (any text); any other brace is an error. A pattern is also rejected when `{any}` is followed by `{amount}`, `{day}` or `{month}` with nothing between them but spaces, digits, dots and commas: `{any}` takes as much text as it can, so it would end inside the number and `12.50` would be read as `50` (D76). A rejected preset is handled as in R47. `docs/operators.md` lists the rule with examples.
    - *scenario* given a preset with the pattern `Saldo {any}.{amount}` or `Saldo {any},{amount}`, when the service loads it, then syslog has one line `operator preset <MCC-MNC> rejected (bad reply pattern), treated as no preset` and `/balance` answers as in R47a; with `Saldo{any}:{amount} EUR` the reply `Saldo racuna:112.50 EUR` gives the balance 112.50
- **R48:** `ROUTER_NAME` from the profile (1 to 20 characters: ASCII letters and digits, space and `-`, starting with a letter or digit) starts every SMS reply: `<ROUTER_NAME>: ...` and `<ROUTER_NAME> commands: ...`. `generic.conf` has `Router`, which the layout below uses (D66).
- **R39:** A person without technical knowledge understands the bot's messages: the first line says what the message is about or whether the internet works; times read `Today 11:11`, `Yesterday 18:40` or `5 Nov 09:12` in the router's time zone, without seconds; apart from the `Tech:` line in `/status` there are no log lines or `key=value` pairs; the text is in English, and emoji are allowed, because the ASCII rule (R29b) is about logs (D49).
  - **R39a:** A sender made of digits only, with at least 9 digits, gets a `+` in front; senders listed in the preset's short codes get the operator's name in front (`Telekom 1466` with `29702`); other senders are shown unchanged.
  - **R39b:** A balance reply has below its text a line that translates the amount and the date until which the credit is valid (`= Balance 0.31 EUR, credit valid until 5 Jan`; without a date in the preset's pattern, only `= Balance <amount> <currency>`); other SMS go without a translation.
  - **R39c:** `/status` has, in order: the verdict, the signal in words with the network type, the number of devices on WiFi, the last known balance with the time it was read (with a warning below the threshold), the speed test line (R41b) and the data of the month (R44) when there are any, the start time with its cause, the last outage (R40a), the action line (R39d), and last a `Tech:` line with bands, RSRP, SINR, ping and WireGuard handshake age. The verdict is `🟢 Internet works`, `🟠 Internet works, but slow (2G backup)` with a line about what works, or `🔴 Internet does not work` with a line about the repair. The start cause is `restarted by self-repair` when the last restart was made by the link repair (R16), `restarted from Telegram (<name>)` or `restarted by SMS from <number>` after a restart asked for in the chat (R45) or by SMS (R46b), and `power cut or manual restart` otherwise. A missing reading gives `unknown` in its field instead of dropping the line.
  - **R39d:** The action line is `❗ Needs a person: unplug the router for 10 s` when the link repair reached the limit (R19), otherwise `⚠️ Top up at least <threshold> <currency>` when the last balance is below the threshold, and `✅ Nothing to do` in all other cases.
  - **R39e:** The signal is `good` with RSRP ≥ -95 dBm and SINR ≥ 10 dB, `poor` with RSRP < -105 dBm or SINR < 0 dB, and `fair` in between (assumption: typical LTE thresholds, to be tuned after a week of signal log).
  - **R39f:** Text that comes from outside (the text and the sender of an SMS, the first name of the person who taps `Restart`, the server name of a speed test) is shown as it is: a sequence in it that looks like one of the router's time markers is not turned into `Today 11:11` (its `@@T` is shown as `@ @T`), and a sender or name that is only an option word for the shell, such as `-n`, is shown.
  - *scenario* given a last signal log line with RSRP -86 dBm and SINR 4.6 dB, a balance of 0.31 EUR read today at 11:05, the threshold 7.50 and no outage, when `/status` comes, then the answer starts with `🟢 Internet works`, has `Signal: fair`, the balance with `today 11:05`, the line `⚠️ Top up at least 7.50 EUR`, and ends with the `Tech:` line
- **R40:** When a link failure (R16) that lasted longer than one repair cycle ends, the chat gets one message `🟢 Internet back` with the start of the failure, its length and the number of router restarts it took (D50).
  - **R40a:** The last outage (start, length, how it ended) survives a router restart and shows in `/status`; flash is written at most at the start of the outage, at the 2G message (R40c) and at the end of the outage (R34c) (D51).
  - **R40b:** When the clock was not yet set from NTP at the start of the failure, the start and the length have a `~` in front; a router restart without a link failure (a power cut, for example) gives no `Internet back` message.
  - **R40c:** When the router switches to the EDGE fallback (R22), the chat gets one message `🟠 Internet slow: switched to 2G backup` with what works and the start of the failure, within 30 s of Telegram being reachable; switching to EDGE again in the same failure (after a restart from the ladder, for example) gives no second message; when the switch (R37c) is `off`, there is no message (D52).
  - *scenario* given a failure from 14:20 fixed after 12 min with one router restart, when the internet comes back, then the chat gets once `🟢 Internet back after 12 min` with `Down since today 14:20` and `fixed by 1 restart`, and `/status` shows this outage in the line `Last outage`
  - *scenario* given the switch `on` and a failure in which the router switches to EDGE after a restart, then restarts a second time and switches to EDGE again, when LTE comes back, then the chat has one 2G message and one `Internet back`; given `/alerts 2g off` before the failure, then the chat has only `Internet back`

- **R41:** `/speedtest` answers at once with `⏱ Speed test started, result in about 60 s.` and measures download, upload, ping and jitter against the nearest speedtest.net server; the result or a failure message reaches the chat at most 120 s after the command, without a confirmation step (D54, D55).
  - **R41a:** The result has a verdict and an "Enough for" line by the download speed: from 50 Mbit/s `fast`, from 10 `OK`, from 2 `slow`, below that `very slow`; it also gives the server with its distance and the data used (the `wwan0` counter during the test, with `~`).
  - **R41b:** The line `Previous today` with the result of the previous test is there only when that test ran on the same day; `/status` has a line with the last test (download, upload, ping, time) only when it ran today. The results are kept in RAM and are gone after a restart (D56).
  - **R41c:** At most one test runs at a time; a command during a test gets `⏳ A speed test is already running`; on the EDGE fallback the test does not start and the chat is told that the router is on 2G; a failed test gives a message with the result of a plain ping (whether the internet works).
  - **R41d:** The test does not hold up SMS forwarding or other commands (R34, R37) and ends within its time limit with no processes left (R38); it never starts by itself, only from the command.
  - *scenario* given a test at 11:40 with the result 129/61, when `/speedtest` comes at 17:52 and gives 99/62 with a ping of 16 ms, then the chat has `Speed test started` at once, and within 120 s the result `🚀 Speed test: fast` with the line `Previous today: 129 ⬇️ / 61 ⬆️ (11:40)`; `/status` has `🚀 Speed test: 99 ⬇️ / 62 ⬆️ Mbit/s · ping 16 ms (today 17:52)`; after midnight both lines are gone

- **R42:** When the profile sets `HC_PING_URL`, the router calls this address (healthchecks.io) every 5 min when it has internet; a normal call writes nothing to syslog or flash, and a failed call does nothing except that the signal does not arrive. An empty `HC_PING_URL` turns the calls off. This does not depend on the Telegram keys (D57).
  - **R42a:** The alarm is sent by healthchecks.io, not by the router: period 5 min, grace 25 min, only the "down" event, no repeats and no "up", by a webhook through the bot (`sendMessage` to `TG_CHAT_ID`) with a short text such as `🔴 Router offline for 30 min`. The healthchecks.io setup lives outside the image (D57).
- **R43:** `/wifi` gives the names and passwords of the enabled WiFi networks from the router's current configuration; when the networks share a password, the second has the note `same password`; a network without a password has `no password` (D58).
- **R44:** `/devices` lists every device with traffic in the current calendar month, in two groups: `Connected now` (WiFi with its band, or cable) and `Not connected now`, each sorted by usage, largest first, with the name from DHCP or `Unknown device` with the end of the MAC address; at most 20 entries in total, the smallest drop off the list but not out of the sum; the router's own traffic (a speed test, for example) is a separate entry `Router itself`; at the end the sum of the month `Data this month: <n> GB (since 1 <month>)`; the same sum is the `📊` line in `/status` below the balance (D59, D63).
  - **R44b:** The router remembers the DHCP name of every MAC address with traffic in the current month, also after its lease expired, so a device switched off for the night keeps its name (D63).
  - **R44a:** The month's counters survive a router restart, losing at most a day on a power cut; flash is written at most once a day and at a stop; the month is taken from the NTP clock, not from the time before the sync (D59).
- **R45:** `/reboot` answers with a question with the buttons `🔄 Restart` and `Cancel`; the restart happens only after a tap on `Restart` within 60 s by a member of the chat `TG_CHAT_ID`; after the tap, a cancel or 60 s the message changes its text and loses its buttons; a tap on an expired button gives the Telegram popup `This button expired, send /reboot again` and does nothing (D60).
  - **R45a:** After the start from such a restart the chat gets one message with the name of the person who tapped and the length of the break; a normal restart (power, link repair) gives no such message.
- **R37d:** `/alerts` shows the 2G message switch also as a button that changes the state and the text of the same message; the command `/alerts 2g on|off` keeps working (D60).
- **R37e:** The chat has a persistent bot keyboard with 9 buttons as in the layout below; the bot sends it with the answer to `/help` and `/start` and once after the first start of the image, and a button acts like its command (`🟢 Status` like `/status` and so on); the bot skips other text without `/`; the keyboard works with the bot's privacy mode on, because the Telegram app sends a tap as a reply to the bot's message that carries the keyboard, and typed commands work in both modes (D64).
- **R37f:** The message of R37e that the bot sends once after the first start of the image starts with two lines, `🔄 Router was reset to its built-in settings.` and `Earlier logs and saved SMS are gone.`, then an empty line and the usual text, when the state on flash was fresh at that start: no flag of R37e and nothing else in `/etc/lw-notify` at the first pass of the service. It is the same single message, never a second one. After a Telegram outage or a restart of the router before the message went out it still carries the lines; an image flashed with its state kept (`sysupgrade -o`: files in `/etc/lw-notify`, no flag) gets the message without them, while a plain `sysupgrade` without `-n` keeps `/etc/config` but not `/etc/lw-notify` and gets the lines; a flash that cannot be written leaves the lines out (D75).
  - *scenario* given a router after a button reset, when the service has started and Telegram answers, then the chat gets one message `🔄 Router was reset to its built-in settings.` / `Earlier logs and saved SMS are gone.` / empty line / `🤖 The router bot is ready. ...` with the keyboard, and no such lines after a later restart of the service or of the router
- *scenario* given a TV `LG-TV` that downloaded 18 GB in the evening and is off since 23:00, with its DHCP lease expired, when `/devices` comes in the morning, then `LG-TV · 18.2 GB` is in the group `Not connected now`, and the sum includes it (R44, R44b)
- *scenario* given a router restarted at 03:00 and 40 GB used since 1 Nov, when `/devices` comes, then the sum is still about 40 GB `since 1 Nov`, and a device without a DHCP name shows as `Unknown device (…6e:94)`
- *scenario* given `/reboot` sent by one member of the group, when another member, Sam, taps `Restart` after 20 s, then the message changes to `🔄 Restarting now (Sam tapped Restart).`, the router restarts, and after the start the chat has once `🟢 Router back after restart (asked by Sam)` with the length of the break; given no tap, then after 60 s the message says `Restart not confirmed, nothing done.` and there is no restart

- **R46:** An SMS from a number in `SMS_ADMINS` (the sender's digits without `+`, a leading `00` or a single leading `0` match when they are at least 8 digits and a number in the list ends with them; for example `05550100123` matches `+15550100123`; a sender with any character other than digits and one leading `+`, a text sender ID such as `X600000001` or a number with a space, is no number and never matches) with the text `status`, `reboot` or `help` (any case, spaces around it allowed) gets an SMS reply to the matched number within 60 s of appearing in the store, even when Telegram is unreachable; any other text from such a number gets the `help` reply, except a text that has the shape of a router reply (it starts with `ROUTER_NAME`, or looks like `<name>: internet OK ...` or `<name> commands: status, reboot`), which gets no reply, so two routers never answer each other; an SMS from other numbers gets no reply. Each of these SMS also reaches the chat like any SMS (R34) (D61, D68, D69).
  - **R46a:** A reply has at most 160 ASCII characters (one GSM-7 SMS) and the content of the layout below; `status` gives the internet state, since when the failure lasts, the repair step with its limit, the cause in words, the 2G state, the signal in words and the last balance with its date; parts that do not fit are left out whole, the cause first.
  - **R46b:** `reboot` first sends its reply, then restarts the router within 30 s; after the start the chat gets a message as in R45a, with the number the command came from. Only a `reboot` restarts that appeared in the store after the service started (what was in the store at the start is old) and whose SMS centre time stamp is at most `SMS_REBOOT_MAX_AGE_MIN` minutes old by the router's clock; when the clock is from NTP, it is also at most as many minutes in the future (a larger difference means the clocks disagree) and a time stamp that cannot be read is not fresh. Without NTP the clock is the one the router had at the start, never ahead of the real time, so only the age is checked: a copy delivered late is refused, and a fresh one is accepted when the centre stamps in the router's time zone. The stamp is read as router-local time, because `sms_tool` drops the zone field, so an admin number whose SMS centre stamps in another time zone cannot restart the router by SMS (a stamp behind the router's zone reads as old and is refused, with NTP or without; one ahead of it is refused only with NTP); `status` and `help` have no age check and are not affected; at most `SMS_REBOOT_MAX_PER_DAY` restarts by SMS per day (the counter survives a restart); an old `reboot`, or one over the limit, gets a reply with the reason, within the reply limit of R46c, and restarts nothing (D65).
  - **R46c:** The router sends at most 10 replies per day in total (the counter survives a restart; flash is written only for a reply); after the limit commands get no reply, while `reboot` still works; a failed send (an empty account, for example) gives one `lw-notify` syslog entry and is not repeated.
  - **R46e:** At the first pass after a flash or a reset (no list of handled SMS yet) the commands found in the store are not run and get no reply, because after a reset old SMS may lie there, and replies would use up the limit of R46c (D65).
  - **R46d:** SMS control also works in an image without Telegram keys when the profile sets `SMS_ADMINS`; an empty `SMS_ADMINS` turns it off (R38a then covers both: without Telegram keys and without `SMS_ADMINS` the service does not start).
  - *scenario* given a failure from 14:20, step 3 of 6, class `hang`, when `status` comes at 14:52 from `+15550100123`, then within 60 s that number gets a reply starting with `Router: internet DOWN since 14:20 (32 min). Self-repair step 3 of 6, cause: modem not responding. 2G backup: off.`, and once the internet is back this SMS is in the chat too
  - *scenario* given 10 replies sent in the last day, when `reboot` comes from a number in the list, then the router restarts without an SMS reply

Message layout (the words may differ, the layout and the information may not):

```
🟢 Internet works

📶 Signal: fair (4G+)
📱 Wi-Fi: 3 devices connected
💶 Balance: 0.31 EUR (today 11:05)
   ⚠️ below 7.50 EUR needed for the next data month
🚀 Speed test: 99 ⬇️ / 62 ⬆️ Mbit/s · ping 16 ms (today 17:52)
📊 Data this month: 42 GB (since 1 Nov)
⏱ On since today 11:01 (power cut or manual restart)
🔧 Last outage: yesterday 14:20, 12 min, fixed by 1 restart
⚠️ Top up at least 7.50 EUR

Tech: B3+B1 · RSRP -86 · SINR 4.6 · ping 50 ms · VPN 2 min

🟠 Internet works, but slow (2G backup)
Messages and email OK, video and calls no.

🔴 Internet does not work
The router is trying to repair it by itself.

🟢 Internet back after 12 min
Down since today 14:20, fixed by 1 restart.

🟠 Internet slow: switched to 2G backup
Messages and email OK, video and calls no.
4G down since today 14:20, the router keeps trying to bring it back.
(/alerts 2g off turns this message off)

⏱ Speed test started, result in about 60 s.

🚀 Speed test: fast

⬇️ Download: 99 Mbit/s
⬆️ Upload: 62 Mbit/s
📶 Ping: 16 ms (jitter 1 ms)
✅ Enough for 4K video on several devices and video calls

Previous today: 129 ⬇️ / 61 ⬆️ (11:40)
Server: Example ISP, Example City (7 km) · ~330 MB used

🟠 Speed test skipped: the router is on the slow 2G backup.
/status shows the details.

⏳ A speed test is already running, the result comes in a moment.

❌ Speed test failed: no speedtest.net server answered.
The internet itself works (ping 30 ms), try again later.

🔔 Automatic messages
New SMS: on · Low balance: on · Internet back: on · 2G backup: on
[ 2G backup: turn off ]

🔴 Router offline for 30 min        (healthchecks.io webhook, R42a)

📶 Wi-Fi for guests

Name: OpenWrt-LTE
Password: xxxxxxxx
5 GHz: OpenWrt-LTE-5G (same password)

📱 Devices this month: 5 (3 connected now)

Connected now:
• iPhone · 5 GHz · 12.4 GB
• Galaxy-S21 · 2.4 GHz · 3.1 GB
• Unknown device (…6e:94) · 2.4 GHz · 0.2 GB

Not connected now:
• LG-TV · 18.2 GB
• Laptop · 7.6 GB

• Router itself · 0.5 GB
Data this month: 42 GB (since 1 Nov)

⚠️ Restart the router?
Internet and Wi-Fi go down for about 2 min.
[ 🔄 Restart ]   [ Cancel ]
 -> 🔄 Restarting now (Sam tapped Restart).
 -> Restart cancelled.
 -> Restart not confirmed, nothing done.        (after 60 s)
 popup on an old button: This button expired, send /reboot again

🟢 Router back after restart (asked by Sam), down 1 min 50 s.

SMS replies (ASCII, one SMS each):
Router: internet OK (4G), signal fair. On since 7 Nov 11:01. Balance 0.31 EUR (7 Nov).
Router: internet DOWN since 14:20 (32 min). Self-repair step 3 of 6, cause: modem not responding. 2G backup: off.
Router: restarting now, back in about 2 min.
Router: reboot not done, it was already waiting when the router started. Send it again.
Router: reboot not done, the SMS is older than 10 min or has no time. Send it again.
Router: reboot not done, 5 restarts by SMS in the last day. Try again later.
Router commands: status, reboot

✉️ +15550100123 · Today 11:11

This is a test SMS.

✉️ Telekom 1466 · Today 11:05

Imate: 0.31 do 05.01.;
= Balance 0.31 EUR, credit valid until 5 Jan

⚠️ Low balance: 0.31 EUR (today 10:00)
Top up at least 7.50 EUR, or the data package will not renew.

When one SMS in the modem cannot be read (R34h):
⚠️ One SMS in the modem cannot be read.
New SMS are not posted here and SMS commands do not work until it is deleted.
Delete it in LuCI: Modem, SMS.

📥 Newest 3 of 27 SMS
(each SMS as above, separated by a line)

/status – is the internet OK
/wifi – Wi-Fi name and password for guests
/devices – who is connected, data this month
/speedtest – measure the internet speed (~60 s)
/balance – ask Telekom for the balance (~1 min)          (operator name from the preset, R47)
/sms – newest SMS (/sms 10 for more)
/alerts – automatic messages, on or off
/reboot – restart the router (asks to confirm)
The bot also posts every new SMS and a low-balance warning by itself.

Once after the first start of the image, with the keyboard (R37e); after a reset or a flash it starts with the two lines of R37f:
🔄 Router was reset to its built-in settings.
Earlier logs and saved SMS are gone.

🤖 The router bot is ready. Tap a button below, or send /help to see what each one does.

Keyboard under the message field (R37e), persistent, resized:
[ 🟢 Status ] [ 📶 Wi-Fi ]  [ 📱 Devices ]
[ ⚡ Speed ]  [ 💶 Balance ] [ ✉️ SMS ]
[ 🔔 Alerts ] [ 🔄 Reboot ] [ ❓ Help ]
```

The "Enough for" line of a speed test result by verdict: `fast` ✅ 4K video on several devices and video calls; `OK` ✅ HD video and video calls; `slow` ⚠️ browsing and low-quality video; `very slow` ❌ messages only.

## Decisions

| ID | Decision | Why |
|---|---|---|
| D1 | Official ImageBuilder 25.12.6 instead of a third-party build such as eko.one.pl (R1) | a stable release and a reproducible build |
| D2 | The configuration lives in the image (R7, R31, R31a) | a button reset must bring back a working router, not bare OpenWrt |
| D3 | LTE only, automatic mode rejected (R10, R11) | a modem that falls back to EDGE does not return to LTE by itself |
| D4 | Band lock per profile (R11c) | a modem may move from a strong band to one that is weak at the site, and data then stalls |
| D5 | AT instead of QMI in the scripts (R12a, R12c) | killed `uqmi` calls used up the modem's QMI client IDs and blocked bringing `wwan` up |
| D6 | Watchcat plus the project's own `wwan-recover` (R14, R15) | watchcat cannot grow the gaps between its actions, so the script only does the router restart |
| D7 | A ladder of growing gaps (R16) | short failures get a quick restart, and a long one does not restart the router all day |
| D8 | A limit of 6 restarts per failure (R19) | a used-up account must not drive the router into restarts for weeks |
| D9 | A cycle counter instead of time (R21, R21e) | the router has no RTC, and after a restart without NTP the clock goes back |
| D10 | The failure class never holds a restart back (R18a) | the modem can report a connection while data is stuck |
| D11 | No step between the `wwan` restart and the router restart (R16) | `AT+CFUN=1,1` and a USB unbind restart the whole board anyway |
| D12 | The EDGE fallback ends at a restart (R24) | a person who restarts the router gets plain LTE back, and the EDGE rules decide again |
| D13 | The generic image has no secrets and no data of a private profile (R4, R4a) | the generic image is meant to be shared; a built image carries its WiFi password and root hash, so the repository is shared, not a built image, and each router gets its own build |
| D14 | Packages modemdata and modemband (R2, R30a) | operators can lock the modem onto one band, so LuCI must show and set the bands and the signal |
| D15 | A private image holds its profile's secrets and stays out of git (R5) | the image is ready to flash with no further steps, and the repository never holds secrets |
| D16 | Automatic SMS cleaning (R26) | a full SMS store stops delivery |
| D17 | Signal log (R28) | a record of the signal makes link failures diagnosable afterwards |
| D19 | HTTPS for LuCI (R30) | the root password does not cross the WiFi in clear text |
| D20 | The profile is a file of variables; `generic.conf` is in git, other profiles are ignored (R3, R5) | one parser checks every key, and private profiles stay local |
| D21 | Defaults of the generic image and random passwords (R7a, R33) | a fixed password in a public repository is known to everyone who reads it |
| D22 | Taking over a dead `wwan-recover` lock (R21a) | without it one killed process turns the repair off until the next restart |
| D23 | The generic image does not force bands (R11c) | a band mask fits only one site |
| D24 | No EDGE when the package is used up (R25) | after a top-up the router should be on LTE at once |
| D25 | WireGuard disabled in the generic image (R7a, R32) | the template knows no server to connect to |
| D26 | Package wifischedule (R2, R30a) | the WiFi can be switched off on a schedule from LuCI |
| D27 | APN from the profile, otherwise empty, and the operator table only as fallback (R13, R13a, R13b) | the APN is not stored on the SIM, and an empty APN lets most networks assign their own |
| D28 | Bands and IMSI through the project's own AT commands on the scripts' port (R12) | `modemband.sh` and a fallback IMSI read used the LuCI port and bypassed the lock |
| D29 | The wait for the lock counts toward the command's limit (R12b, R13c) | the APN script runs while the link comes up, and a hotplug script stuck on an AT command can take the router down |
| D30 | EDGE after the first failed restart, a failure ends only on LTE, LTE probes only after the limit (R15, R16, R22, R23, R23a) | a failure that a restart did not fix is a failure of the LTE network, not of the modem, so waiting for the sixth restart before EDGE means almost a day without access |
| D31 | Class `account` from an operator DNS answer, only for cycles in LTE-only mode, limit class saved in the state (R18, R18b, R18c) | with a used-up package the operator DNS answers, while "nothing comes back" depended on whether someone was using the WiFi |
| D32 | EDGE comes back after a start in passive mode (R22a) | without it a power cut or a manual restart during a long failure leaves the router without access until LTE returns |
| D33 | The snapshot does not wait for a busy AT lock (R20a) | the restart must not depend on the modem that is suspected of hanging |
| D34 | APN fallback from the second failed attempt, with the "from table" marker, in the background (R13b, R13d) | the first attempt with an empty APN fails also on networks that accept it, and a script blocking in hotplug can hang the router |
| D35 | Code, profiles and images in this folder, the ImageBuilder in the work folder (R3, R5) | the sources stay small and versioned, and the heavy downloads stay out of the repository |
| D36 | A password card with hints, passwords repeated between builds (R33, R33a) | after a reset and after a later image the router still has the passwords of the card that came with it, and its behaviour is explained there, not in syslog |
| D37 | Image identity and a first-start entry (R7b) | a reset erases logs and state, so without it a router after a reset cannot be told from one without a failure, nor can the image version be known |
| D38 | Class `sim` for a SIM without `READY` (R18, R18d) | a restart does not enter a PIN, and a SIM with a PIN otherwise gives a day of restarts without a message |
| D39 | A fixed format of the failure state and of the end of `wwan-recover` entries (R21d, R21e) | a person or a tool reads the course of a failure without guessing, also when the clock went back |
| D40 | Class order `sim`, `account`, `hang`, with `sim` and `account` kept to the end of the failure (R18) | watchcat bringing `wwan` up while the package is used up gave random `hang` classes that opened EDGE against D24 |
| D41 | The LTE probe after the limit runs as normal cycles in LTE-only mode, its class replacing the limit class (R18b, R23) | otherwise a package that runs out after the limit never gives the class `account`, and the router goes back to EDGE |
| D42 | Logs of the image's scripts in English (R29b) | log lines are read by people and tools in any language, and ASCII shows correctly everywhere |
| D43 | SMS forwarding to Telegram, turned on by profile keys (R34, R3) | the owner sees the operator's SMS without logging in to the router; the generic image has no bot |
| D44 | One reminder when the balance drops below the profile's threshold, without recognising packages (R35, R36) | packages differ, and an account may be left empty on purpose |
| D45 | A two-way bot with English commands that only read (R37, R37a) | the token sits in the image, so a taken-over bot must not be able to change anything |
| D46 | Polling the store every 15 s in a resident service instead of listening for `+CMTI` (R34, R38) | forwarding within seconds, and a constant reader on the AT port without `sms_tool` hung the modem |
| D47 | The automatic balance query as the only SMS the image sends by itself (R27, R35) | the balance cannot be read any other way, and one query a week keeps the cost low |
| D48 | The bot can live in a group (R37b) | membership of the group decides who may use the bot, with no list in the image |
| D49 | Messages for a non-technical person, technical data in one line at the end of `/status` (R39 to R39e) | not everyone in the chat is technical, and the numbers stay available for diagnosis |
| D50 | A message when the internet comes back after a failure longer than one repair cycle (R40) | nothing can be said during the failure, and short drops give no message |
| D51 | The last outage in `/status`, with an approximate time when NTP is missing (R40a, R40b) | the router has no RTC (D9), and an approximate time is better than none |
| D52 | A message when switching to 2G, once per failure (R40c) | Telegram works on 2G, so the owner can learn about a failure while it lasts |
| D53 | A switch for the 2G message in the bot (R37, R37a, R37c) | the message is useful to some and noise to others; the switch does not touch the link |
| D54 | `/speedtest` from the bot through `speedtestcpp` and speedtest.net servers (R41, R37a, R2) | a measurement of its own through `uclient-fetch` stalled on TLS and broke uploads; the larger image is accepted |
| D55 | No confirmation for the test, and no data warning in the start reply (R41) | one tap is enough, and a test uses a few hundred MB, small next to a typical package |
| D56 | Previous and last result only from today, kept in RAM (R41b) | an older result says little about the link now |
| D57 | The "offline" alarm comes from healthchecks.io as a webhook through the bot, after 30 min of silence, once, without "up" (R42, R42a) | the router cannot reach Telegram during a failure; the alarm must not spam, and its short text guesses no cause, since a planned power-off is silent too |
| D58 | `/wifi` with name and password (R43) | the guest password can be passed on from a phone |
| D59 | `/devices` and the month's data from `nlbwmon`, with its database on flash (R44, R44a) | a database in RAM was zeroed at every restart and, after a start without NTP, landed in the wrong month |
| D60 | `/reboot` and the `/alerts` switch with Telegram buttons (R45, R37d) | one tap to confirm instead of typing |
| D61 | SMS control with `status`, `reboot`, `help` from the profile's numbers, without confirmation, with a limit of 10 replies per day (R46 to R46d, R27) | it is the only channel when data does not work; the limit protects the balance and stops a loop with an automatic responder |
| D62 | No band unlock during a failure | the LTE band mask does not apply to EDGE, and unlocking a band the profile excluded can stall data, so it would spoil the LTE probes after the limit |
| D63 | `/devices` also shows devices not connected now, with their remembered name (R44, R44b) | a device switched on only in the evening otherwise vanished from the list, its data showing only in the sum |
| D64 | A persistent bot keyboard, with the bot's privacy mode on (R37e) | a non-technical person taps instead of remembering commands, and the bot still receives only commands and replies to its own messages, not the rest of the group conversation |
| D65 | A `reboot` by SMS only when fresh and within a daily limit, numbers compared by their end (R46, R46b) | an SMS delivered hours late, or lying in the store at the start, must not restart the router; a sender number can be forged, hence the restart limit; the network may give the sender in national form; without NTP the age is still checked, because the unsynced clock is never ahead of real time (a late copy is refused), and only the bound towards the future is left out; stated limit: the centre's stamp is read as router-local time (`sms_tool` drops the zone), so an admin number whose SMS centre stamps in another time zone cannot restart by SMS, and `status` is not affected, as it has no age check |
| D66 | Operator preset chosen by IMSI, `LOW_BALANCE` in the preset's currency, `ROUTER_NAME` in SMS replies (R47, R48) | the generic image must work with any SIM: a balance only where a preset exists, and a new operator is one data file with no code change |
| D67 | Joining SMS sent in parts, 10 min for a missing part (R34g) | a long SMS otherwise arrives as several messages with broken sentences, sometimes in reverse order; after 10 min an incomplete one goes out so nothing is lost |
| D68 | Commands in SMS replies and in `README.md` in lower case (`status`, `reboot`); the router takes any case (R46a) | upper case suggests that commands must be typed in upper case |
| D69 | An SMS reply goes to the number from `SMS_ADMINS` without `+` (R46) | `sms_tool` 2025.08.23 encodes `+` as a digit, so the network accepted replies to `+<number>` that never arrived; a number of 6 or more digits goes out as international anyway, and a national sender form has no country code |
| D70 | The project is called `lonewrt`: scripts, paths and variables use the prefix `lw` (`lw-notify`, `/usr/lib/lw/`, `LW_*`), uci package `lonewrt` | a template repository needs a name of its own, and the prefix keeps its files apart from OpenWrt's |
| D71 | The sender field of the SMS list is repaired, and an unreadable list is reported once (R34h, R26f) | `sms_tool` does not escape the sender, one text sender ID with a quote would stop forwarding, SMS control and the cleaning without a trace; skipping the message would need a parser of our own and the owner would not see it, while the repair is two characters in one field that ends at a fixed boundary; what cannot be repaired is reported after 3 reads in a row instead of being a silent state |
| D72 | A message of the operator's sender is a balance only within 10 min of a query of the router; every matching reply in that window counts (R36) | the sender of an SMS can be forged, and a forged balance would change `/status`, and with an amount above the threshold stay out of the chat; an answer after 10 min is shown as an ordinary SMS, so the owner sees what arrives; "once" was rejected: a forged `Imate: 99.00` between the weekly query and the real low reply would take the slot and hide the low-balance warning, which worked before; accepted leftover: a forged reply after the real one, inside the window, changes what `/status` shows until the next real reply (the warning has already gone out); the first scan after a flash or a reset keeps the old way, because it forwards nothing, there is no stored balance yet, and a forged value there is replaced by the next real reply |
| D73 | The root password may be given in clear text as `ROOT_PASSWORD`, next to `ROOT_PASSWORD_HASH` (R33b) | owners should not need to know how to make a crypt hash; the profile already holds the WiFi key in clear text and should be 0600 (R3a), and only the hash goes into the image |
| D74 | WiFi encryption `psk2` (WPA2 only) instead of `psk-mixed` (R7) | the owner's decision of 2026-11-09: WPA1/TKIP is off, and every device of the guests supports WPA2; accepted cost: a very old device that knows only WPA1 does not connect |
| D75 | The first greeting of the bot says the router was reset, in the same message (R37f) | a button reset wipes the logs, the SMS archive and the SMS limit counters, and the owner abroad would learn of it only indirectly; the router cannot tell a reset from a flash, both start with empty state, so the lines stand for "fresh state", decided at the first pass from an empty `/etc/lw-notify`, because the keyboard flag alone is also missing after an update with the state kept (`sysupgrade -o`) from an image without the keyboard; a plain `sysupgrade` keeps `/etc/config` but not `/etc/lw-notify`, so it gets the lines too; one message, because the owner wants no extra notification |
| D76 | A reply pattern with only number characters between `{any}` and a number placeholder is rejected, not repaired (R47c) | the preset is a hand-written data file and the fault would show only as a wrong balance when the first reply comes; a rejection says so in syslog at once, while changing the pattern silently would change what the file says; the rule is on the characters (spaces, digits, dot, comma) and not on the two forms seen, because every such gap lets `{any}` end inside the number |
| D77 | The third-party `.apk` files are checked against `deps.lst` when `build.sh` copies them, only the pinned set is copied, and old versions are removed by exact package name (R2a) | a file in `dl/extra` that was swapped or left over after the download check would otherwise go into an image that carries the profile's secrets |
| D78 | A profile, or a private key file of its folder, readable by others with a secret in it is a warning, not an error (R3a) | the build is correct either way and a shared machine is the owner's call; the warning costs one `chmod` |
| D79 | The wait before watchcat restarts `wwan` is a profile key, `LINK_RESTART_AFTER_S`, a whole number from 120 to 900 with the default 120 (R14, R14a) | on 2026-11-10 the operator dropped the data session while the modem stayed registered, nothing showed in the logs, and with the earlier fixed 300 s the outage was about 6 min, almost all of it waiting for the restart that brought the link back within 40 s. The default 120 s halves that; the cost is an interface restart, about 40 s without internet, on a glitch that would have healed alone. Lower bound 120 s: the ping period is 60 s, so two failed pings in a row. Upper bound 900 s, checked for two cases. A failure that starts after boot: the first router restart is at the 6th failed cycle, at the earliest 1500 s after the outage begins (R16, 6 cycles of 5 min counted from the first failed cycle); watchcat restarts at most 920 s after the drop (60 s steps counted from the last answer, plus the pings), the link is back about 40 s later, so 540 s remain. A failure already there at boot: watchcat counts only from uptime 900 and restarts at about 1820 s, the link is back at about 1860 s; wwan-recover counts cycles only from uptime 600 (R17), so its 6th cycle, the router restart, is at 2100 s at the earliest, and 240 s remain. With 1200 s the boot case would restart the router first (the interface restart would come at about 2420 s), which is why the bound is 900; the highest value that still passes the boot case is about 1020 s. The earlier 300 s was far from this edge (link back after about 415 s) |

## Risks

- A bad image on the MF289F: recovery is only over UART with the case opened (`docs/development.md`, "Recovery"), so every image passes `sysupgrade -T` before a flash.
- Flash wear from the persistent log: the log has 1 MB with rotation, the signal log is in RAM, cron does not log job starts, and the failure state is written only on a change. During test days the log grew to about 570 KB in a day and a half, more than half of it netifd entries from manual `wwan` restarts; that is hundreds of KB a day on UBIFS with wear levelling. In a long failure 2 MB of log with the `.old` file hold only a few days of history.
- A used-up package: the image cannot fix it, it only recognises it and stops restarting sooner; the warning comes from the heartbeat on the server side.
- Flashing over the tunnel: a mistake in the tunnel or band fields of a profile cuts the router off until someone is on site, so an image with changed tunnel fields is flashed only with someone at the router.
- The operator changes bands or priorities: the band mask is in the profile, and the signal log shows the change.
- The bot token in a private image: whoever gets the image file or the router can write as the bot and read commands; the bot has only reading commands (R37a), and the token is changed in @BotFather and with a new build. The token is also visible in the arguments of the `uclient-fetch` process during a request, that is to every process on the router, but not in the logs. The address of the healthchecks.io check (`HC_PING_URL`) is visible the same way, in the arguments of the `uclient-fetch` process every 5 min; whoever reads it can send false signals that the router is alive, which hides an outage, and can do nothing else with it.
- Every profile secret stays readable in the image's read-only part for whoever holds the router or the image: the tunnel key, the SSH host keys, the WiFi password, the root password hash, the APN password, the bot token and the heartbeat address. First boot deletes `zz-lw-config` only from the writable layer. The router stands among strangers, so the limit is set on the WireGuard server: the router's peer gets only its own tunnel address and may not open connections into the owner's network.
- Another modem firmware: the SMS store size, the `ZSNT` codes and the receive store falling back to `SR` were measured on `BD_TMOPLMF289F1V1.0.0B03`; on another firmware they must be measured again, and the requirements win over the modem's behaviour.

## Acceptance

Fixture: an MF289F with a working SIM, wired to a laptop; for the generic image, an MF289F with a SIM of another operator.
Needed: the work folder with the ImageBuilder and packages, `unsquashfs`, `openssl`, `ssh` and `scp` over the cable.
Each point is a separate reason to reject:

1. **Build:** a private profile and `generic.conf` both build; the image manifest has every package of the "Included" table and none of the "Left out" table; the rootfs of the private image has the image's files and the profile's values; the rootfs of the generic image meets the no-secrets rules (R4, R4a); a broken profile and a broken script stop the build (R3, R6); git ignores the private profile and image (R5); `generic-passwords.txt` has the passwords and hints, and a second build does not change them (R33, R33a); `<vm>` passes the first start with the first-start table and the `lw-firstboot` entry, a start without the AT port, a power cut during the first start, a reset through `firstboot`, cron, and the persistent log with rotation (R7, R7b, R8, R8a, R29); `<tests>` passes, including the modem and SMS scripts (R11 to R13d, R26 to R26e) and `<ladder>` with the results of the ladder, class and EDGE rules in every scenario: hang, used-up package with and without DNS, SIM with PIN, dead LTE with working EDGE, start in passive mode, EDGE without network after the limit, dead lock, busy AT lock, with state and entries in the format of the state rules (R16, R18, R18c, R18d, R19, R20a, R21a, R21d, R21e, R22, R22a, R23a, R25); `sysupgrade -T` on the router passes (R1, R2).
2. **After flashing a private image, within 5 min:** `ip -4 addr` on `wwan0` has an address; `wg show wg0` has a handshake younger than 3 min; both WiFi networks are up; `AT+ZSNT?` gives `6,0,0`; `AT+ZNLOCKBAND?` gives the mask of the profile's bands; `AT+CPMS?` has `ME` three times; syslog has `lw-modem-mode` with `modem OK` (entries about setting the state before it are allowed at the first start); the crontab matches the first-start table; watchcat runs; LuCI answers over HTTPS, `http://<router>/` redirects to it and the modemdata page shows a reading; `/tmp/lw-signal.log` has a new line; `/root/openwrt.log` grows and has an `lw-firstboot` entry with the content of `/etc/lw-build` (R7, R7b, R10, R11, R11a, R12, R13, R14, R28, R29, R30, R30a, R31).
3. **Button reset with someone at the router:** the router comes back with the same SSH host key, point 2 passes again, and this time syslog has no entries about setting the mode or bands (R7, R11a); the first message in the chat starts with the two reset lines (R37f).
4. **Dry runs and the lock on the router:** `DRYRUN=1 wwan-recover` changes no state; `DRYRUN=1 MAX=0 KEEP=0 lw-sms-clean` prints every index and deletes nothing; an AT command with a busy lock ends within its limit without an orphan; a snapshot with a busy lock ends within 30 s (R12b, R20a, R21b, R26a, R26d).
5. **Generic image on a router with another operator's SIM:** LTE comes up on that SIM, and syslog shows whether with the empty APN or from the table; the WiFi has the name and password from `generic-passwords.txt`; `wg0` is disabled, and once enabled in LuCI it comes up; a change made in LuCI survives a restart (R4, R7a, R9, R13, R32).
6. **Notifications on a router with a private image:** `<tests>` passes the notification tests with a stand-in Telegram API (R34 to R38, including no internet, a restart, a low threshold, a foreign chat); an SMS from the owner's phone reaches the chat within 30 s; `/status`, `/sms 3` and `/balance` get answers; after a router restart that SMS does not come a second time; `logread` and `/root/openwrt.log` do not contain the token; the generic image does not run the `lw-notify` service (R34, R34a, R34d, R36, R37, R38). `<tests>` checks the messages against the layout, including `/status` without a signal reading, at the repair limit and on EDGE, `Internet back` after a failure with a restart and without NTP, and no such message after a power cut, the 2G message once per failure and its `/alerts` switch, an SMS with Latin-1 bytes and a message rejected by Telegram (R34e, R34f), `/speedtest` with a stand-in client: result, previous from today and from yesterday, a second test during one, EDGE, failure, a hung client and an SMS forwarded during a test (R41 to R41d); on the router `/speedtest` gives a result within 120 s; `<tests>` also checks the `HC_PING_URL` call and its absence, `/wifi`, `/devices` with the `nlbwmon` database after a restart and with a device not connected after its lease expired (R44b), the `/reboot` buttons (tap, cancel, 60 s, expired button, foreign chat) and the message after such a restart (R42 to R45a); on the router the healthchecks.io alarm arrives after 30 min with the antenna unplugged or the SIM removed, and `/reboot` with the button restarts the router; `<tests>` checks the SMS commands (number in the list and outside it, letter case, the limit of 10, `reboot` after the limit, a failed send, no Telegram keys), a number in national form, a `reboot` that is too old, one lying in the store at the start and one over the daily limit (R46 to R46d); `<tests>` checks the preset `29702` and a SIM without a preset (no SMS, the `not available` line), labels and currency from the preset and `ROUTER_NAME` in SMS replies (R47 to R48); on the router `status` from the owner's phone gets a reply within 60 s; on the router `/status` has the layout above, and an SMS from the owner's phone shows its sender with `+` (R39 to R40b).

A private image is accepted after points 1 to 4 and 6, the generic image after points 1 and 5.

### Unverified

- Keyboard taps with privacy mode on (R37e, D64): seen working in Telegram Desktop; the Android app's source sends taps the same way; Telegram for iOS and Telegram Web are not checked, and a tap made while the user is replying to another message goes to that message instead, so the bot does not receive it. Next check: one tap from each app in use.
- Start without the modem and an interrupted first start on the hardware (R8, R8a): `<vm>` checks them on x86_64, not on the router's NAND flash. Next check: a restart with the SIM removed, with someone at the router.
- Repeatability of the first-start scripts (R8a): fstools 25.12.6 erases the overlay after every cut before `done`, so `<vm>` also passes with a script that is not repeatable (checked by injecting one). Next check: none while fstools works this way.
- A power cut after a button reset (R8a, R9): on one router the first power cut about 7 min after a completed start after a reset erased the overlay, while later ones in normal operation did not; `<vm>` with an ext4 overlay does not reproduce it, and a repeat on the router (reset, 7 min, power cut) did not either. The only difference seen: the reset came about 6 min after `sysupgrade -n`. Next check: save `dmesg` and `logread` at the next case.
- The modem after a power cut (R8): once, after a short power cut, the modem did not show up on USB, and another power cut helped; whether a restart from the ladder brings it back is unknown. Next check: `ls /sys/bus/usb/devices/2-1` at the next case, then `reboot`.
- The counter across a restart and the state write (R16a, R21, R21c): `<ladder>` does not restart the host or interrupt a write. Next check: a scenario with an interrupted write, and the first ladder restart on the router.
- LTE probe from EDGE, mode confirmation and the end of EDGE at a restart (R23, R24): `<ladder>` replaces `lw-fallback` with a stub. Next check: a test for `lw-fallback` with stand-ins for `ifup`, `uci` and the mode read.
- Class `account` on a real network (R18): the operator DNS answering with a used-up package has been seen, but the rule has not run with a used-up package. Next check: the class entry in the log the next time a package runs out.
- Class `sim` on a real modem (R18, R18d): the answer of `AT+CPIN?` has been seen only for a missing SIM (`SIM not inserted`), not for a SIM with a PIN. Next check: a SIM with the PIN turned on, with someone at the router.
- APN fallback (R13b): on the test network an empty APN works, so nobody has seen the switch to the table. Next check: a SIM of an operator that rejects an empty APN, or a profile with a wrong APN on purpose.
- Error paths of a real modem (R11b, R13c, R26c, R26e): `<tests>` fakes a silent port with a stand-in, and a real modem hang may look different. Next check: the log entries at the next hang.
- A kernel identical to the official one (R1): `sysupgrade -T` does not prove it. Next check: compare the kernel checksum of the image with the official 25.12.6 image.
- Firewall directions of the tunnel (R31a): nobody has checked traffic from the LAN into the tunnel. Next check: a ping from a LAN device to the server's tunnel address must fail.
- Rotation of the persistent log on the router (R29): `<vm>` checks it, but nobody has looked at the `.old` file on a router. Next check: the size of `/root/openwrt.log*` after a week.
- The SMS centre's time zone for the owner's numbers (R46b, D65): the stamp is read as router-local time, and it was only observed with the phone and the router in the same zone. Next check: send an SMS from the owner's phone at home and abroad and compare the `timestamp` in `sms_tool recv` with `date`.
- Cost of the balance query (R35, R37): one query with the shipped preset did not change the balance, and no price list for it was found. Next check: the balance before and after the first weekly query.
- The `Internet back` message on a real failure (R40, R40b): `<tests>` fakes the repair state and the clock. Next check: the message in the chat after the next failure longer than 5 min.
- Signal thresholds (R39e): taken from typical LTE values, not from a site. Next check: the RSRP and SINR distribution from a week of signal log.
- Watchcat after the limit (R14): not observed in passive mode. Next check: watchcat entries in `/root/openwrt.log` at the next limit.
