# Changelog

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

[0.1.0]: https://github.com/DamianPala/lonewrt/releases/tag/v0.1.0
