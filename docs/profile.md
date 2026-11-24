# Profile keys

A profile is `profiles/<name>.conf`: lines `KEY='value'` (single quotes, no `'` inside), `#` comments.
The [configurator](https://damianpala.github.io/lonewrt/) writes one for you; by hand, start from a copy of `profiles/generic.conf`.
`build.sh` parses the file and never sources it.
Every key of `profiles/generic.conf` must be present, once.
A missing key, an unknown key, a key given twice, an empty value where none is allowed or a malformed value stops the build with the key's name, never its value.

| Key | Meaning | When empty |
|---|---|---|
| `HOSTNAME` | the router's name: letters, digits and `-`, up to 63 characters, starting with a letter or digit | not allowed |
| `LAN_IP` | the router's LAN address; the network is a /24 | not allowed |
| `ZONENAME` | time zone name, e.g. `Europe/Warsaw` (the configurator offers LuCI's list) | not allowed |
| `TIMEZONE` | the time zone as the POSIX string the router's clock uses, e.g. `CET-1CEST,M3.5.0,M10.5.0/3` | the build takes the string of `ZONENAME` from the configurator's list, and stops when the zone is not on it |
| `WIFI_SSID` | the Wi-Fi name, one network on both bands; 1 to 32 characters | not allowed |
| `WIFI_KEY` | the Wi-Fi password, 8 to 63 printable ASCII characters | drawn, see [Passwords and the card](#passwords-and-the-card) |
| `WIFI_COUNTRY` | two-letter regulatory country in capitals, e.g. `PL`; set it to the country the router runs in | not allowed |
| `WIFI_CHANNEL_2G`, `WIFI_CHANNEL_5G` | `auto` or a channel number | not allowed |
| `WIFI_HTMODE_2G`, `WIFI_HTMODE_5G` | the channel width: `HT20`, `HT40`, `VHT80`... | not allowed |
| `ROOT_PASSWORD` | the root password in clear text, 8 to 63 printable ASCII characters; the build hashes it and the image holds only the hash. Set this or `ROOT_PASSWORD_HASH`, not both | drawn when both are empty |
| `ROOT_PASSWORD_HASH` | the root password as a crypt(3) hash (it starts with `$`), e.g. from `openssl passwd -6` | drawn when both are empty |
| `SSH_KEYS` | public SSH keys of the people who may log in as root, separated by `;`, see [SSH keys](#ssh-keys) | only the keys of the profile's folder, if any |
| `WWAN_APN`, `WWAN_AUTH`, `WWAN_USERNAME`, `WWAN_PASSWORD` | LTE access; auth is `none`, `pap`, `chap` or `both` | the network assigns an APN; when that fails, the router takes one from its own short list of operators |
| `WWAN_PIN` | the PIN of the SIM card, 4 to 8 digits, see [SIM PIN](#sim-pin) | for a card without a PIN |
| `LTE_BANDS` | comma list of LTE bands to lock, e.g. `1,3,20` | bands untouched |
| `WG_ENABLED` | `1` turns the WireGuard client on, `0` leaves it off | not allowed |
| `WG_PRIVATE_KEY`, `WG_ADDRESS`, `WG_PEER_PUBLIC_KEY`, `WG_ENDPOINT_HOST` | the tunnel: the router's private key, its address (space-separated CIDR list), the server's public key and the server's name or address | allowed only when `WG_ENABLED` is `0` |
| `WG_ENDPOINT_PORT`, `WG_ALLOWED_IPS`, `WG_KEEPALIVE` | the server's port, the networks reached through the tunnel (space-separated CIDR list) and the keepalive interval in seconds | left unset |
| `TS_ENABLED` | `1` puts Tailscale into the image (packages `tailscale` and `kmod-tun`, about 8 MB more in the root file system; the build stops above 15 500 000 bytes), `0` leaves it out | not allowed |
| `TS_ADVERTISE_LAN` | `1` offers the router's LAN (`LAN_IP` with a /24 mask, written as a network address such as `192.168.5.0/24`) to your Tailscale account; `0` does not. The build warns when the LAN is `192.168.0.0/24` or `192.168.1.0/24`, the network of many homes. Needs `TS_ENABLED` `1`: with `0` here, `TS_ADVERTISE_LAN` `1` stops the build | not allowed |
| `TS_AUTHKEY` | optional: an auth key from Tailscale's admin page (`tskey-auth-` and then letters, digits and `-`) that signs the router in without a click. An API token (`tskey-api-...`) or an OAuth client secret (`tskey-client-...`) stops the build. Needs `TS_ENABLED` `1`: with `0` here, a set `TS_AUTHKEY` stops the build | no key: the router is signed in with a link |
| `TG_BOT_TOKEN`, `TG_CHAT_ID` | the Telegram bot's token (from @BotFather) and the ID of your chat or group with it (a group's ID is negative, e.g. `-1001234567890`); both set turns on forwarding of SMS, alerts and the bot commands | no notifications, also when only one of the two is set |
| `LOW_BALANCE` | balance threshold in the currency of the SIM's operator preset: up to 4 digits and, after a dot, up to 2 more, e.g. `7.50`. Turns on the weekly balance check (Monday 10:00) and the low-balance alert; needs the bot and a preset for the SIM's operator, see [operators.md](operators.md) | no check, no alert |
| `HC_PING_URL` | `https` ping address of a healthchecks.io check, called every 5 minutes | no heartbeat |
| `OP_MCCMNC`, `OP_NAME`, `OP_CURRENCY`, `OP_BALANCE_QUERY_NUMBER`, `OP_BALANCE_QUERY_TEXT`, `OP_BALANCE_REPLY_FROM`, `OP_BALANCE_REPLY_PATTERN`, `OP_SHORT_CODES` | a balance check for an operator the image has no preset for: the first 5 digits of the SIM's IMSI, and the operator's balance query and reply. Set all of them or none; only `OP_SHORT_CODES` may stay empty. The values and the build's check are in [operators.md](operators.md) | only the image's preset (`29702`, Telekom Montenegro) |
| `SMS_ADMINS` | phone numbers that may control the router by SMS (`status`, `reboot`, `help`), comma list in international form, e.g. `+15550100123,15550100456`, see [SMS control](#sms-control) | no SMS control |
| `SMS_REBOOT_MAX_AGE_MIN` | an SMS `reboot` older than this many minutes is refused, see [SMS control](#sms-control); `1` to `9999`, `generic.conf` has `10` | not allowed |
| `SMS_REBOOT_MAX_PER_DAY` | at most this many restarts by SMS in 24 h; `1` to `9999`, `generic.conf` has `5` | not allowed |
| `ROUTER_NAME` | the router's name at the start of its SMS replies (`<name>: internet OK ...`), so a reply that reaches another router running this image is not answered back; 1 to 20 ASCII letters, digits, spaces and `-`, starting with a letter or digit, e.g. `Home 2-b` | not allowed |
| `LINK_RESTART_AFTER_S` | seconds without an answer to the pings after which the router restarts its mobile connection, see [Link restart](#link-restart); `120` to `900`, `generic.conf` has `120` | not allowed |
| `LOG_LEVEL` | `info` or `debug`; `debug` is for a test period, see [Log level](#log-level) | not allowed |

`WIFI_KEY`, `ROOT_PASSWORD`, `ROOT_PASSWORD_HASH`, `WWAN_PASSWORD`, `WWAN_PIN`, `WG_PRIVATE_KEY`, `TS_AUTHKEY`, `TG_BOT_TOKEN`, `HC_PING_URL` and `SMS_ADMINS` are secrets or private data.
They end up in the image as root-readable files (`ROOT_PASSWORD` as its hash), so an image built from a profile with them is private too, and git ignores every profile except `generic.conf`.
`build.sh` warns when a profile with one of the secrets (all but `SMS_ADMINS`), or a private SSH host key in `profiles/<name>/`, is readable by group or others: run `chmod 600` on those files.

## Passwords and the card

`build.sh` draws a random password for an empty `WIFI_KEY`, and a root password when `ROOT_PASSWORD` and `ROOT_PASSWORD_HASH` are both empty.
A build that draws one writes the password card `image/<name>-passwords.txt` (mode 0600): the Wi-Fi name, both passwords and hints for the person who gets the router.
Later builds of the profile take the drawn passwords from the card, so keep it: without the card the next build draws new ones.
Once a card exists, every build rewrites it from what the image holds, so a password the profile now sets replaces the card's.
When the profile gives only `ROOT_PASSWORD_HASH`, the card has no `root=` line and says that root uses the hash from the profile.
Every build hashes the root password with a new salt, so the hash in the image changes between builds while the password stays.
A build on GitHub writes no card: it refuses a profile with an empty `WIFI_KEY` or with both root keys empty, so that every run gives the same passwords; the configurator can draw them for you.

## SSH keys

Each key of `SSH_KEYS` is `<type> <base64 data> [comment]` with the type `ssh-ed25519`, `ssh-rsa` or `ecdsa-sha2-nistp256`, e.g. `ssh-ed25519 AAAAC3...u1x laptop;ssh-ed25519 AAAAC3...Qk2 phone`.
Public keys are not secrets.
Spaces around `;` are dropped; an empty entry (`;;`, a trailing `;`) or an entry that is not a key of its type stops the build, naming the key and the entry's number.

The folder `profiles/<name>/` may hold three more files, each optional:

- `authorized_keys`: its lines are copied as they are after the keys of `SSH_KEYS`, so options such as `from="..."` belong here. A key that `SSH_KEYS` already has (same type and data, whatever the comment) is written once.
- `dropbear_ed25519_host_key` and `dropbear_rsa_host_key`: the router's own SSH host keys. With them the router keeps its host key over a flash or a reset with the button, so SSH does not warn that the key changed.

## SIM PIN

A SIM without a PIN is the simplest: take the PIN off in a phone and leave `WWAN_PIN` empty.
With `WWAN_PIN` set the router unlocks the card at every start of the connection, also after a reset with the button; a PIN entered in LuCI instead is lost at a reset or a flash.
The router tries the PIN only while the card has all 3 tries left, and stops after a wrong one.
So a wrong `WWAN_PIN` costs up to 2 tries and the router alone cannot block the card, but a card with fewer than 3 tries left stays locked, also with the right PIN: enter the right PIN once in a phone, which gives the card its 3 tries back.
This key has not been tried on a card with a PIN yet.

## SMS control

Each number of `SMS_ADMINS` is an optional `+` and 6 to 15 digits, no spaces.
Write the numbers in international form; a sender in national form (`0...`) still matches by its last 8 or more digits.
The commands are read in any case (`status`, `STATUS`).

A `reboot` is refused when its SMS is older than `SMS_REBOOT_MAX_AGE_MIN` minutes, with or without a synced clock.
The time stamp of the SMS centre is read as the router's local time, so an admin number whose SMS centre stamps in another time zone cannot restart by SMS (`status` still works).

## Link restart

The router pings every 60 s.
After `LINK_RESTART_AFTER_S` seconds without an answer it restarts the `wwan` interface, which costs about 15 s without internet.
Shorter heals a dropped data session sooner but restarts on glitches that would pass alone.
The upper limit keeps this restart ahead of the restart of the whole router.
The pings go to 8.8.8.8 and 1.1.1.1 (and to the same services over IPv6 when the connection has IPv6) through the mobile connection only; the hosts and the address family shown for the watchcat entry `wwan_soft` in LuCI are not used.

## Log level

`LOG_LEVEL` takes `info` or `debug`, exactly; any other value, `DEBUG` included, stops the build.
With `debug` the persistent log `/root/openwrt.log` rotates at 2 MB instead of 1 MB (in an image with Tailscale it stays at 1 MB, because Tailscale takes about half of the free flash), every 5-minute signal sample is written to it as well, and `lw-linkwatch` (the watcher that restores a data session the network dropped) logs each step, a snapshot of the modem and a heartbeat every 5 minutes.
All of it is extra flash writes, so go back to `info` after the test period.
