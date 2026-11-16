# lonewrt

lonewrt builds an OpenWrt image for the ZTE MF289F, an LTE router, meant for a place where nobody looks after it.
You describe one router in a profile file and build a flashable image from it.
The router comes back configured after a button reset, restarts a hung link by itself, and reports to you over Telegram and SMS.

I built it for a flat abroad with guests and no admin on site. What it fixes:

- **A guest presses reset.** The settings live in the image, so the router comes back as you configured it, not as bare OpenWrt. Changes made later in LuCI go with the reset, and so do the logs and the SMS archive on the router.
- **The modem hangs.** When the network only drops the data session, a small watcher starts it again within seconds. Otherwise the router restarts the connection, then the whole router, waiting longer each time. It gives up restarting when a restart cannot help: a used-up data package or a SIM asking for its PIN. When LTE stays dead it switches to 2G where the network still has it, enough for the tunnel and the bot, not for video, and back to LTE once that works again.
- **The data package expires and you learn it a week later.** Every SMS on the SIM is posted to your Telegram chat. An SMS that arrives during an outage is posted once the internet is back. With a preset for your operator the router also checks the balance once a week and warns you when it is low. One preset is included, Telekom Montenegro; yours is a 7-line data file.
- **Someone asks for the Wi-Fi password at 23:00.** You tap a button in Telegram and the bot posts the Wi-Fi name and password with a QR code that a phone camera scans to join. Other buttons give the link state, the connected devices, the newest SMS, a speed test (about 330 MB of your data) and a restart. Typed commands do the same: `/status`, `/wifi`, `/devices`, `/sms`, `/speedtest`, `/balance`, `/alerts`, `/reboot`, `/help`.
- **The internet is down and so is the bot.** A healthchecks.io heartbeat tells you from the outside, and the router posts when it is back and how long it was gone.

What the chat looks like, with the keyboard that saves remembering commands (made-up data, rendered from the bot's code by `tools/tg-preview`):

<img src="docs/img/telegram-status.png" width="260" alt="Telegram chat: a tap on Status and the router's reply with signal, Wi-Fi, balance, data and uptime"> <img src="docs/img/telegram-wifi.png" width="260" alt="A tap on Wi-Fi: a QR code photo with the network name and password, ready to forward to a guest"> <img src="docs/img/telegram-devices.png" width="260" alt="A tap on Devices: connected and earlier devices with their data this month, and the button to name a device">

Phone numbers you list can also text `status` or `reboot` to the SIM, for the day Telegram is not an option.
The router checks only the sender's number, and numbers can be faked. So SMS can only ask for the state and a restart, and restarts by SMS are limited to 5 a day.

The image is experimental. It runs on one router in daily use; expect rough edges on other setups.
The full behaviour, with reasons, is in [SPEC.md](SPEC.md).

## What you need

- A ZTE MF289F that already runs OpenWrt. Installing OpenWrt over the stock firmware is not covered here.
- Either a Linux x86_64 build host, or no Linux at all: a web browser, a GitHub account and the router's web page (LuCI), see [Build without Linux](#build-without-linux). The Linux host needs `bash`, `python3`, `openssl`, `curl`, `tar`, `zstd`, `make`, `flock` and GNU awk. The tests also want `bubblewrap`, `squashfs-tools`, `qrencode` and `zbar-tools`. Details in [docs/development.md](docs/development.md).
- For the notifications, a Telegram bot token and a chat. For remote access, a WireGuard server. For the heartbeat, a healthchecks.io check. Each is optional.

## Quick start

```sh
./fetch-deps.sh                      # ImageBuilder, packages, test rootfs into work/ (about 530 MB)
cp profiles/generic.conf profiles/mine.conf
$EDITOR profiles/mine.conf           # at least WIFI_COUNTRY; every key is explained in the file
./build.sh mine                      # image/mine-sysupgrade.bin, image/mine.manifest
```

Leave `WIFI_KEY`, `ROOT_PASSWORD` and `ROOT_PASSWORD_HASH` empty and the build generates random passwords and writes a password card to `image/mine-passwords.txt`.
Later builds of the same profile reuse the card, so the passwords stay.
Keep the card: the drawn passwords are stored nowhere else, and without it the next build draws new ones.
To choose the root password yourself, write it in `ROOT_PASSWORD`; the build puts only its hash into the image.

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

You can also write the profile in the configurator, a web page in one file: open `configurator/index.html` from disk in a browser, or use the hosted copy at https://damianpala.github.io/lonewrt/ (it sends nothing either way).
A coding agent can do the build and the flash for you, with the safeguards of the agent skill [skills/lonewrt/SKILL.md](skills/lonewrt/SKILL.md): it never shows your passwords and flashes only after you say yes.
Reference for the profile keys: [docs/profile.md](docs/profile.md).
Balance checks for your operator: [docs/operators.md](docs/operators.md).

## Build without Linux

You need a GitHub account, a web browser and a ZTE MF289F that already runs OpenWrt. The image is built on GitHub's machines from your own profile and you flash it in LuCI, the router's settings page.
The profile holds your Wi-Fi and root passwords, so everything below is private: your repository, the saved profile file and the download.

1. **Make your repository from the template.** Open [DamianPala/lonewrt-build](https://github.com/DamianPala/lonewrt-build), click **Use this template** > **Create a new repository**, and choose **Private**. A run in a public repository stops before it builds anything, because every signed-in GitHub user can download what a public repository's run makes.
2. **Fill in the configurator.** Open https://damianpala.github.io/lonewrt/ (the project's GitHub Pages; if it does not open, download `configurator/index.html` from the [project](https://github.com/DamianPala/lonewrt) and open it from your disk). It runs in your browser and sends nothing. Read the release version the page shows at its top: you build that version in step 4. Go through the fields (each one is explained), and **set both passwords**: the Wi-Fi password (`WIFI_KEY`) and the root password (`ROOT_PASSWORD`). A build on GitHub draws no password, so that every build gives you the same ones; a profile without them is refused.
3. **Save the profile and keep it.** Click **Save as a file** (it makes `router.conf`) and keep that file somewhere private: it holds your passwords, and the configurator of a later release loads it, so you never fill the form from scratch again. Then put its text into GitHub: in your new repository open **Settings > Secrets and variables > Actions > New repository secret**, name it `LW_PROFILE`, open the saved file in a text editor, copy all of it and paste it as the value.
4. **Run the build.** Open **Actions > build > Run workflow**. In **version** type the release version the configurator page showed (empty means the newest release, which may be newer than the page you used). Leave **name** as `router` and **test** unticked. It takes some minutes. If it stops, its message names the problem (a missing secret, a profile key, an empty password); nothing is uploaded then.
5. **Download the image.** Open the green run and download the artifact at the bottom of the page. **It is kept for 7 days**, and the summary of the run names the last day. Unzip it: you get `router-sysupgrade.bin`, the image, and `router.manifest`, the package list. The summary also gives the image's sha256 (a fingerprint of the file) for the check below.
6. **Back up the router.** In LuCI open **System > Backup / Flash Firmware** and click **Generate archive**. Keep the file: it can restore your old settings.

Then flash, in one of two ways.

### Flash in LuCI

1. In LuCI open **System > Backup / Flash Firmware** and next to **Flash new firmware image** click **Flash image...**, then choose `router-sysupgrade.bin`.
2. LuCI shows the size and the checksum of the file. Compare the checksum with the sha256 in the run's summary. If they differ, stop and download again.
3. **Untick "Keep settings"** (the wording differs a little between versions). Without it the router takes everything from your profile, as after a button reset. This is what `sysupgrade -n` does in the commands of the Quick start.
4. Click **Continue** and leave the router alone. It is back after about 100 seconds, with LTE and the tunnel about 70 seconds later. Use a cable if you can, because the Wi-Fi drops while it flashes.

Not yet tried on an MF289F: the steps above are LuCI's standard flash, which is meant to do what `sysupgrade -n` does. <!-- verify: LuCI flash pending, SPEC Unverified -->
LuCI refuses an image that does not fit the router, but this model has no failsafe for a broken one: the way back is opening the case and a serial console ([docs/development.md](docs/development.md), "Recovery"). Flash only the image you built here.

### Flash with a coding agent

Give a coding agent (Claude Code, Codex and others) the file [skills/lonewrt/SKILL.md](skills/lonewrt/SKILL.md) and your saved profile file, and tell it what you want: "build my image on GitHub and flash it". It builds from your file without printing your passwords, makes a backup, checks the image and flashes only when you say yes to that flash. It needs `ssh` access to the router with a key, and it never asks you for a password in the chat.

### The router's new SSH key

Each flash and each button reset gives the router a new SSH host key, because a GitHub build has no host keys in its profile folder. The next `ssh root@<router address>` from your computer then stops with a warning that the host identification has changed. That is expected here. Once you are sure it is your router, remove the old entry and connect again:

```sh
ssh-keygen -R <router address>
```

Afterwards read [After flashing](#after-flashing): the Wi-Fi name and password, how to open LuCI, what the router does on its own, and what the button reset does.

## After flashing

These are the hints that the password card carries when the build draws a password.
A build on GitHub writes no card, because both passwords are the ones you put in your profile, so the hints are here, for you and for whoever gets the router.
The router's own settings page is called LuCI.

- **Wi-Fi.** The network name is `WIFI_SSID` of the profile and the password is `WIFI_KEY`. It is one network on both the 2.4 and the 5 GHz band.
- **Opening LuCI.** Join the router's Wi-Fi or plug a cable into its LAN port, and open `https://` followed by the router's address (`LAN_IP` of the profile, `192.168.1.1` unless you changed it) in a browser. The user is `root`; the password is `ROOT_PASSWORD` of the profile, or the password behind `ROOT_PASSWORD_HASH` if you gave a hash.
- **The browser warns about the certificate.** This is expected: the router signs its own certificate, so the browser cannot know it. Choose Advanced and continue.
- **The button reset.** Holding the router's reset button puts back the settings of the image, passwords included: the ones of your profile. Changes you made later in LuCI, the logs and the SMS archive on the router are lost.
- **A SIM card with a PIN.** The router cannot use it. Take the PIN off in a phone, or enter it in LuCI: Network > Interfaces > WWAN > Edit > PIN.
- **No internet 5 minutes after the router starts.** Enter your operator's APN (the mobile data name, on the operator's site) in LuCI: Network > Interfaces > WWAN > Edit > APN, then Save & Apply.
- **LTE only.** The router uses LTE and nothing else. The network mode (2G/3G/LTE) cannot be changed in LuCI: the router sets LTE again at every start.
- **The router restarts itself.** When the internet fails, it first restarts the connection, then, if that does not help, the whole router. To turn the restarts off, go to LuCI: System > Scheduled Tasks and delete the line with `/usr/sbin/wwan-recover`.
- **SMS on the SIM.** When the SIM holds more than 30 messages, the router copies all of them to `/root/sms-archive/` once a day at 04:10 and deletes the oldest, keeping 20, so new SMS (top-ups, package expiry) keep arriving.
- **The Wi-Fi country.** It is the `WIFI_COUNTRY` of the profile. To change it without a new image, go to LuCI: Network > Wireless > Edit on each radio > Advanced Settings > Country Code.

## What goes over the network

The build downloads the ImageBuilder and the official packages from `downloads.openwrt.org`, the modem tools `modemband` and `modemdata` from `dl.eko.one.pl`, the Polish OpenWrt site that packages them, and three LuCI apps for the modem, the bands and SMS from 4IceG's GitHub releases.
The ImageBuilder, the third-party packages and the test files are pinned by sha256 in `deps.lst`.
The official packages are downloaded by the ImageBuilder and checked with OpenWrt's signing keys, which come inside the pinned ImageBuilder.
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
Any built image carries its Wi-Fi password and root hash, so share the repository, not a built image, and build one image per router.

Whoever gets hold of the router also has its WireGuard private key.
So on your WireGuard server allow the router's peer only its own tunnel address, and block connections from it into your network; the router never needs them.

## Project

Solo project, best effort, no response-time promise.
Built with AI coding agents under my direction. The behaviour is pinned by the tests in `tests/`; [docs/development.md](docs/development.md) says what they cover and what only the real router can show.
The build targets OpenWrt 25.12.6; another release means updating the pins, also described there.

- Bugs: open an issue with the OpenWrt version, the contents of `/etc/lw-build`, what you did and expected, and the `lw-` lines of `logread`. Remove phone numbers, tokens and keys first.
- Security: use "Report a vulnerability" on the Security tab, not a public issue.
- Pull requests for bug fixes are welcome; open an issue first for anything larger.
- Working on the code: [docs/development.md](docs/development.md) for layout and tests, [AGENTS.md](AGENTS.md) if a coding agent does the typing.

Licence: MIT, see [LICENSE](LICENSE). The packages the ImageBuilder puts into the image keep their own licences.
