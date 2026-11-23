# Changelog

## [0.6.0] - 2026-11-23

### Added

- Optional Tailscale remote access (profile key `TS_ENABLED`, default off): the bot sends a sign-in link, and then you reach the router's settings page and SSH by its name from your own devices, with no server of your own. The router cannot open connections to your other devices, only they can reach it, and the [Tailscale guide](docs/tailscale.md) has the steps, including the access policy that keeps a stolen router out of your other devices. Tried in a virtual machine with a real Tailscale account, not on a real router yet
- Optional auth key `TS_AUTHKEY` adds the router to your account without the link; the router uses it once
- Tailscale can also share the router's LAN with your devices (`TS_ADVERTISE_LAN`), after you approve the route in the admin console; the devices on the LAN see the router's address. If the router's LAN is `192.168.0.x` or `192.168.1.x`, the build and the configurator warn you, because the route then clashes with the network of most homes you connect from
- The bot tells you once each when the router waits for a sign-in, when it was added, when the LAN route was approved, 14 days before the sign-in ends and when the router dropped out of your account, with a new link where you need one; `/tailscale` and its button give a fresh link or the router's Tailscale state, `/status` has a Tailscale line, and owners without Telegram text `tailscale` to the SIM
- Configurator: a Tailscale section, with warnings about the router's free space and a LAN that many homes share, and a button that moves the router to a rarer LAN address
- With Tailscale on, the image is about 18 MB and the free space on the router is about 4 to 6 MiB instead of 12.5 MiB, so install few extra packages later

### Changed

- **BREAKING:** a profile made for 0.5.x lacks three keys, and the build stops with the name of the first one. Migration: add `TS_ENABLED='0'`, `TS_ADVERTISE_LAN='0'` and `TS_AUTHKEY=''` (copy them from `profiles/generic.conf`), or load the profile into the configurator and download it again

## [0.5.1] - 2026-11-22

### Fixed

- `./fetch-deps.sh` and every build on GitHub stopped with "sha256 mismatch" for `libjpeg-turbo-3.1.1-r1.apk` since 2026-11-19, when OpenWrt rebuilt two packages the tests use without a new version number. `deps.lst` has the sums of the rebuilt files, whose hashes match OpenWrt's signed package index. The image itself was not affected: `build.sh` never used these files

## [0.5.0] - 2026-11-22

### Added

- Profile keys `OP_MCCMNC`, `OP_NAME`, `OP_CURRENCY`, `OP_BALANCE_QUERY_NUMBER`, `OP_BALANCE_QUERY_TEXT`, `OP_BALANCE_REPLY_FROM`, `OP_BALANCE_REPLY_PATTERN` and `OP_SHORT_CODES`: a balance check for an operator the image has no preset for, on every way to build, also on GitHub. The build checks the values with the code the router reads presets with and stops with the key's name. Not tried with a real operator other than Telekom Montenegro yet. Add the eight lines with empty values to an existing profile (see `profiles/generic.conf`), or load the profile into the configurator
- Configurator: a section "Balance check for another operator" with a box where you paste a balance SMS and see the amount and date the router would read from it
- Profile key `WWAN_PIN` for a SIM card with a PIN, also in the configurator: the router unlocks the card at every start, so a button reset no longer leaves it offline until someone enters the PIN in LuCI. Not tried on a card with a PIN yet. Add the line `WWAN_PIN=''` to an existing profile, or load the profile into the configurator
- Configurator: a button at an empty `WIFI_KEY` and `ROOT_PASSWORD` draws a password in the browser, in the form the build draws them, so a build on GitHub no longer means making up two passwords

### Changed

- **BREAKING:** a profile made for 0.4.0 lacks nine keys, and the build stops with the name of the first one. Migration: add `WWAN_PIN=''` and the eight `OP_*` lines with empty values (copy them from `profiles/generic.conf`), or load the profile into the configurator and download it again
- Docs: `README.md` is shorter and reordered: "What it solves" comes first, a table says where to start, and "Limits" and "Docs" are sections of their own
- Docs: what the build downloads and what the router talks to moved from `README.md` to `docs/network.md`
- Docs: the tools a Linux build host needs are listed only in `docs/development.md` ("Build host"), and the messages about a missing tool from `build.sh` and from a run on GitHub point there
- Password card and `README.md` ("After flashing"): a new hint says what to do when SSH warns that the router's host key changed after a flash or a button reset
- Agent skill: it says where the code comes from (for a local build, a checkout of the release the profile was made for), forbids opening the profile, the card, an image or a backup with the agent's own file tools as well, and asks before a flash whether the router will answer on another address and still accept a key login
- Agent skill: a shorter description, one example instead of two, and the way to build is chosen before the profile is copied
- Docs: `docs/operators.md` starts with what a preset gives you, says how a preset for another operator gets into an image (the `OP_*` keys of the profile) and how to try one on a running router before building
- `profiles/generic.conf`: the comments are one-line reminders now, and `docs/profile.md` is the one place that says what each key takes
- Docs: `packages.md` says what the third-party packages are and how they are pinned, how much room the image leaves on the router and how to change the package list; the history of how the list was made is gone
- Docs: `docs/porting.md` covers the SIM's PIN (`WWAN_PIN`), more places that depend on QMI (`WWAN_AUTH`, the `wwan_4` interface, `set_up_bandz.sh`) and two more measurements, and its long steps are lists
- Docs: `docs/profile.md` states the format of more keys (`LOW_BALANCE`, `HOSTNAME`, `WIFI_SSID`, `TG_CHAT_ID` of a group and others), says what the SSH host key files of a profile's folder are for, and its long table cells are sections below the table

### Fixed

- Agent skill: on GitHub it could take an earlier run of the repository for the one it had just started; it now waits for the new run, always names the version and reads the message of a failed run from its log
- Agent skill: a router this machine had never connected to was reported as "no key login"; the two failures are now told apart
- Agent skill: its examples named release 0.1.0, which cannot be built on GitHub, and the configurator's version line, the `test` field of a run and the generic image were described wrongly
- Docs: `docs/operators.md` named a chat line that `/balance` does not show, left out that a reply counts as the balance only within 10 minutes of a query the router sent, and gave a test step that could not be followed
- Docs: the commands of `docs/porting.md` that read a router's settings let the SIM's PIN and some Wi-Fi passwords through (`pincode`, `sae_password`, `key1` to `key4`); the filter now drops every option whose name looks like a password, a key or a PIN
- Docs: `docs/porting.md` named files that hold no such thing (watchcat and cron in `zz-lw-config`, `lw-linkwatch` in `generic.conf`) and left out tests and documents that carry the ZTE model or this repository's name
- Docs: `packages.md` gave eko.one.pl as the source of the LuCI apps that come from 4IceG's GitHub releases, a reason for `coreutils-stty` that no script of the image matches, and an image size "not yet measured"; it also left out that the signal log needs `modemdata`
- `profiles/generic.conf`: a comment said that a restart of the mobile connection costs about 40 s without internet; it is about 15 s
- Password card and `README.md` ("After flashing"): the hint about the network mode said "LTE only"; it now says that the router sets LTE at every start and switches to 2G (EDGE) only while LTE stays dead after a restart
- `./fetch-deps.sh --help` and `tests/vm/run-all.sh --help` ended with a line of the script's code
- Tests: the full build test skipped the modem and Wi-Fi packages of the default set when it compared an image with `packages.md`; it now checks them, refuses a table row it cannot read, and compares the package list of the VM bench, whose description claimed three packages it does not install

## [0.4.0] - 2026-11-20

### Added

- Profile: `TIMEZONE` may be left empty; the build then takes the time zone string for `ZONENAME` from the configurator's list, and stops when the zone is not on it
- Docs: `docs/porting.md`, a guide for moving lonewrt to another OpenWrt router with an LTE modem, written for a coding agent that does the port with you in a fork

### Changed

- Configurator: a profile loaded with an empty `TIMEZONE` keeps it empty, and the field appears with a note only when the build could not fill it (a zone not on the list)

## [0.3.0] - 2026-11-17

### Changed

- Configurator: the time zone is picked from a list, and the page fills in the time zone string the router's clock uses, so the two can no longer disagree
- Configurator: settings that matter only with another one appear when they apply: the WireGuard settings once WireGuard is on, the APN login once an APN is set, the low-balance alert once the Telegram bot is set, the SMS limits once an admin number is set; the root password and its hash hide each other
- Configurator: SSH keys go one per line, as in a `.pub` file; the profile text still joins them with `;`
- Docs: the LuCI flashing steps in `README.md` have been tried on an MF289F

## [0.2.1] - 2026-11-16

### Fixed

- A build on GitHub failed or hung at its tests, because GitHub's Ubuntu 24.04 machine has an older bubblewrap and Python and runs its steps with SIGPIPE ignored; the tests now pass there, so the run gives the image to download
- An `SSH_KEYS` entry whose key data ends in an extra `=` is now refused on every Python version, not only on newer ones

## [0.2.0] - 2026-11-16

### Added

- Build your image on GitHub, with no Linux machine: make a private repository from the template [lonewrt-build](https://github.com/DamianPala/lonewrt-build), put the profile into its secret `LW_PROFILE` and start the workflow; the run checks the profile, builds and tests the image and keeps it as a download for 7 days. Such a run needs both passwords set in the profile, so every run gives the same ones
- Configurator: one web page, hosted at https://damianpala.github.io/lonewrt/ or opened from disk, that writes a profile in the browser and sends nothing anywhere
- Agent skill for coding agents (`skills/lonewrt/SKILL.md`): it builds the person's image on their machine or on GitHub and flashes it after a backup, without showing a password or token
- Profile key `SSH_KEYS` for public SSH keys that may log in as root, also settable in the configurator

## [0.1.0] - 2026-11-15

First public release, experimental: it runs on one router in daily use.

### Added

- Build a flashable OpenWrt 25.12.6 image for the ZTE MF289F from one profile file; empty passwords are drawn at random and kept on a password card, so later builds keep them
- The settings live in the image, so a router reset with the button comes back configured, not as bare OpenWrt
- Self-repair of the LTE link: a lost data session is started again within seconds, otherwise the connection and then the whole router are restarted with growing waits, up to 6 restarts per outage (2 when the data package is used up or the SIM asks for its PIN), and the router switches to 2G while LTE stays dead
- Telegram bot with a button keyboard: link status, Wi-Fi, devices, newest SMS, speed test, balance, alerts, restart and help, also as typed commands
- The Wi-Fi button answers with a QR code photo and a caption that can be forwarded to a guest as it is
- Data used this month per device, with names you give devices from the chat
- Every SMS on the SIM is posted to the chat, including those that arrive during an outage
- Balance check for your operator with a small preset file (Telekom Montenegro included) and a weekly low-balance warning
- Messages when the internet is back (start, length, restarts it took) and when the router switches to 2G
- Optional healthchecks.io heartbeat, so you hear about a router that is offline from the outside
- Listed phone numbers can text `status` or `reboot` to the SIM, at most 5 restarts a day
- Optional WireGuard tunnel for remote access, LuCI apps for the modem, the LTE bands and SMS, persistent logs, and the release version in `/etc/lw-build`

[0.6.0]: https://github.com/DamianPala/lonewrt/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/DamianPala/lonewrt/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/DamianPala/lonewrt/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/DamianPala/lonewrt/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/DamianPala/lonewrt/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/DamianPala/lonewrt/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/DamianPala/lonewrt/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/DamianPala/lonewrt/releases/tag/v0.1.0
