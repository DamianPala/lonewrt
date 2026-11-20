# Changelog

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

[0.4.0]: https://github.com/DamianPala/lonewrt/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/DamianPala/lonewrt/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/DamianPala/lonewrt/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/DamianPala/lonewrt/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/DamianPala/lonewrt/releases/tag/v0.1.0
