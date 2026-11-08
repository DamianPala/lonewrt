# Profile keys

A profile is `profiles/<name>.conf`: lines `KEY='value'` (single quotes, no `'` inside), `#` comments.
`build.sh` parses it and never sources it.
Every key of `profiles/generic.conf` must be present.
A missing key, an unknown key, an empty value where none is allowed or a malformed value stops the build with the key's name, never its value.

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
| `LOW_BALANCE` | balance threshold in the currency of the SIM's operator preset, e.g. `7.50`; turns on the weekly balance SMS and the low-balance alert (needs the bot). Used only when the SIM has an operator preset, see [operators.md](operators.md) | yes |
| `HC_PING_URL` | https ping address of a healthchecks.io check, called every 5 minutes | yes: no heartbeat |
| `SMS_ADMINS` | phone numbers that may control the router by SMS (`status`, `reboot`, `help`, any case); comma list, each `+` optional then 6 to 15 digits, no spaces, e.g. `+15550100123,15550100456`; write them in international form; a sender's national form (`0...`) still matches by its last 8+ digits | yes: no SMS control |
| `SMS_REBOOT_MAX_AGE_MIN` | an SMS `reboot` older than this many minutes (by the SMS centre time, with an NTP clock) is refused; default `10` | no |
| `SMS_REBOOT_MAX_PER_DAY` | at most this many restarts by SMS in 24 h; default `5` | no |

`WG_PRIVATE_KEY`, `TG_BOT_TOKEN`, `HC_PING_URL` and `SMS_ADMINS` are secrets or private data.
They end up in the image as root-readable files, so an image built from a profile with them is private too, and git ignores every profile except `generic.conf`.

## Passwords and the card

An empty `WIFI_KEY` or `ROOT_PASSWORD_HASH` is drawn at random by `build.sh` and written to `image/<name>-passwords.txt` (mode 0600), together with hints for the person who gets the router.
A later build of the same profile reuses the card, so the passwords do not change.
The image keeps its profile name, build date and a hash of `src/` in `/etc/lw-build`; after a flash the same line goes to the log as `lw-firstboot`.
