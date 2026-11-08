# lonewrt

lonewrt builds an OpenWrt image for the ZTE MF289F, an LTE router, meant for a place where nobody looks after it.
You describe one router in a profile file and build a flashable image from it.
The router comes back configured after a button reset, restarts a hung link by itself, and reports to you over Telegram and SMS.

I built it for a flat abroad with guests and no admin on site. What it fixes:

- **A guest presses reset.** The settings live in the image, so the router comes back as you configured it, not as bare OpenWrt. Changes made later in LuCI go with the reset, and so do the logs and the SMS archive on the router.
- **The modem hangs.** The router restarts the connection, then the whole router, waiting longer each time. It gives up restarting when a restart cannot help: a used-up data package or a SIM asking for its PIN. When LTE stays dead it switches to 2G where the network still has it, enough for the tunnel and the bot, not for video, and back to LTE once that works again.
- **The data package expires and you learn it a week later.** Every SMS on the SIM is posted to your Telegram chat. An SMS that arrives during an outage is posted once the internet is back. With a preset for your operator the router also checks the balance once a week and warns you when it is low. One preset is included, Telekom Montenegro; yours is a 7-line data file.
- **Someone asks for the Wi-Fi password at 23:00.** You tap a button in Telegram and the bot posts the Wi-Fi name and password. Other buttons give the link state, the connected devices, the newest SMS, a speed test (about 330 MB of your data) and a restart. Typed commands do the same: `/status`, `/wifi`, `/devices`, `/sms`, `/speedtest`, `/balance`, `/alerts`, `/reboot`, `/help`.
- **The internet is down and so is the bot.** A healthchecks.io heartbeat tells you from the outside, and the router posts when it is back and how long it was gone.

What the chat looks like (made-up values):

```
🟢 Internet works
📶 Signal: good (4G+)
📱 Wi-Fi: 3 devices connected
💶 Balance: 7.80 EUR (Yesterday 09:12)
⏱ On since 5 Nov 08:30 (power cut or manual restart)
✅ Nothing to do

Tech: B3+B1 · RSRP -85 · SINR 12 · ping 36 ms · VPN 3 s ago
```

Phone numbers you list can also text `status` or `reboot` to the SIM, for the day Telegram is not an option.
The router checks only the sender's number, and numbers can be faked. So SMS can only ask for the state and a restart, and restarts by SMS are limited to 5 a day.

The image is experimental. It runs on one router in daily use; expect rough edges on other setups.
The full behaviour, with reasons, is in [SPEC.md](SPEC.md).

## What you need

- A ZTE MF289F that already runs OpenWrt. Installing OpenWrt over the stock firmware is not covered here.
- A Linux x86_64 build host with `bash`, `python3`, `openssl`, `curl`, `tar`, `zstd`, `make`, `flock` and GNU awk. The tests also want `bubblewrap` and `squashfs-tools`. Details in [docs/development.md](docs/development.md).
- For the notifications, a Telegram bot token and a chat. For remote access, a WireGuard server. For the heartbeat, a healthchecks.io check. Each is optional.

## Quick start

```sh
./fetch-deps.sh                      # ImageBuilder, packages, test rootfs into work/ (about 530 MB)
cp profiles/generic.conf profiles/mine.conf
$EDITOR profiles/mine.conf           # at least WIFI_COUNTRY; every key is explained in the file
./build.sh mine                      # image/mine-sysupgrade.bin, image/mine.manifest
```

Leave `WIFI_KEY` and `ROOT_PASSWORD_HASH` empty and the build generates random ones and writes a password card to `image/mine-passwords.txt`. Later builds of the same profile reuse the card, so the passwords stay. Keep the card: the passwords are stored nowhere else, and without it the next build draws new ones.

Then back up the router and flash. The examples use `192.168.1.1` for the router's current address:

```sh
ssh root@192.168.1.1 'sysupgrade -b -' > backup.tar.gz
scp -O -r root@192.168.1.1:/root ./router-root                 # logs and SMS archive
scp -O image/mine-sysupgrade.bin root@192.168.1.1:/tmp/fw.bin
ssh root@192.168.1.1 'sysupgrade -T /tmp/fw.bin && sysupgrade -n /tmp/fw.bin'
```

The router is back after about 100 s, LTE and the tunnel about 70 s later.
The flash cuts your connection, so do not run it over the router's own Wi-Fi unless you can afford to lose it.
To go back, flash any other OpenWrt sysupgrade image the same way and restore the backup with `sysupgrade -r`.

This model has no failsafe for a broken image: the way back is opening the case and a serial console ([docs/development.md](docs/development.md), "Recovery"). That is why `sysupgrade -T` checks the image before the flash. The image also keeps the official kernel and only adds packages and files on top.

Reference for the profile keys: [docs/profile.md](docs/profile.md).
Balance checks for your operator: [docs/operators.md](docs/operators.md).

## What goes over the network

The build downloads the ImageBuilder and the official packages from `downloads.openwrt.org`, the modem tools `modemband` and `modemdata` from `dl.eko.one.pl`, the Polish OpenWrt site that packages them, and three LuCI apps for the modem, the bands and SMS from 4IceG's GitHub releases.
Every download is checked against a sha256 pinned in `deps.lst`.
The build sends nothing about your profile anywhere.
[packages.md](packages.md) lists what ends up in the image.

The router talks to the operator, the NTP pool and, depending on the profile:

| Destination | When | What it gets |
|---|---|---|
| `api.telegram.org` | Telegram keys set | SMS texts and senders, alerts, the replies to your commands (the Wi-Fi password among them) |
| your healthchecks.io URL | set | an empty GET every 5 minutes |
| `8.8.8.8`, `1.1.1.1`, DNS for `openwrt.org` | always | a ping and one lookup every few minutes, to tell whether the link works |
| the nearest speedtest.net server | you ask for a speed test | about 330 MB of test traffic |
| your WireGuard server | tunnel enabled | the tunnel |
| the operator's balance number | the weekly check and `/balance` | one SMS, which may cost money |
| your admin numbers | they text the router | one reply SMS each |

There is no telemetry.
The bot answers only in the chat from the profile, and anyone in that chat can read the Wi-Fi password and restart the router, so keep it to people you trust.
A profile with a Telegram token, a WireGuard key, a heartbeat URL or admin numbers makes a private image: those values sit in the image as root-readable files, so do not pass that image on.

## Project

Solo project, best effort, no response-time promise.
Built with AI coding agents under my direction. The behaviour is pinned by the tests in `tests/`; [docs/development.md](docs/development.md) says what they cover and what only the real router can show.
The build targets OpenWrt 25.12.6; another release means updating the pins, also described there.

- Bugs: open an issue with the OpenWrt version, the contents of `/etc/lw-build`, what you did and expected, and the `lw-` lines of `logread`. Remove phone numbers, tokens and keys first.
- Security: use "Report a vulnerability" on the Security tab, not a public issue.
- Pull requests for bug fixes are welcome; open an issue first for anything larger.
- Working on the code: [docs/development.md](docs/development.md) for layout and tests, [AGENTS.md](AGENTS.md) if a coding agent does the typing.

Licence: MIT, see [LICENSE](LICENSE). The packages the ImageBuilder puts into the image keep their own licences.
