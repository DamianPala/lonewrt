# What goes over the network

The build downloads the ImageBuilder and the official packages from `downloads.openwrt.org`, the modem tools `modemband` and `modemdata` from `dl.eko.one.pl`, the Polish OpenWrt site that packages them, and three LuCI apps for the modem, the bands and SMS from 4IceG's GitHub releases.
When the host has no GNU awk, `fetch-deps.sh` also downloads gawk from `archive.ubuntu.com`.

The ImageBuilder, the third-party packages and the test files are pinned by sha256 in `deps.lst`.
The official packages are downloaded by the ImageBuilder and checked with OpenWrt's signing keys, which come inside the pinned ImageBuilder.
The build sends nothing about your profile anywhere.
[packages.md](../packages.md) lists what ends up in the image.

The router talks to the operator, the NTP pool and, depending on the profile:

| Destination | When | What it gets |
|---|---|---|
| `api.telegram.org` | Telegram keys set | SMS texts and senders, alerts, the replies to your commands (the Wi-Fi password among them) |
| your healthchecks.io URL | set | an empty GET every 5 minutes |
| `8.8.8.8`, `1.1.1.1` | always | a ping every 60 seconds, to tell whether the link works |
| the operator's DNS server | the link is down | a lookup of `openwrt.org`, at most one every 5 minutes, to tell a used-up data package from a dead link |
| the nearest speedtest.net server | you ask for a speed test | about 330 MB of test traffic |
| your WireGuard server | tunnel enabled | the tunnel |
| the operator's balance number | the weekly check and `/balance` | one SMS, which may cost money |
| your admin numbers | they text the router | one reply SMS each |
| Tailscale's control server, `login.tailscale.com` | Tailscale on | the sign-in, the router's name and its public keys |
| Tailscale's relay servers, `derpN-all.tailscale.com`, HTTPS on port 443 | Tailscale on, when two devices cannot connect directly | encrypted traffic between your devices, relayed |
| your other Tailscale devices | Tailscale on | encrypted traffic, directly over UDP port 41641 (Tailscale's default) when the network allows |

There is no telemetry. In a Tailscale image the OpenWrt package starts Tailscale with `TS_NO_LOGS_NO_SUPPORT=true`, so it does not upload its diagnostic logs to `log.tailscale.com`.
The bot answers only in the chat from the profile, and anyone in that chat can read the Wi-Fi password and restart the router, so keep it to people you trust.
A profile with a Telegram token, a WireGuard key, a heartbeat URL or admin numbers makes a private image: those values sit in the image as root-readable files, so do not pass that image on.
Any built image carries its Wi-Fi password and root hash, so share the repository, not a built image, and build one image per router.

Whoever gets hold of the router also has its WireGuard private key.
So on your WireGuard server allow the router's peer only its own tunnel address, and block connections from it into your network; the router never needs them.

## Tailscale

With `TS_ENABLED='1'` the image gives Tailscale these rules:

- The interface `tailscale0` is in its own firewall zone, `tailscale`. Input is accepted, so your devices reach the router. Output and forward are rejected, so the router starts no connection into your account.
- With `TS_ADVERTISE_LAN='1'` and the route approved, the zone forwards only to `lan`, and that forwarding is masqueraded: devices on the LAN see the router's LAN address, not the sender's. Nothing passes from `lan` or `wan` into the zone.
- Tailscale's own firewall handling is off, and it takes no DNS settings or routes from your account, so the firewall and DNS stay as the image sets them.
- Outgoing, the router uses UDP port 41641 (Tailscale's default), UDP port 3478 to learn its public address, and HTTPS port 443 to the control and relay servers. It opens no port on its internet side for Tailscale.

Tailscale's own access policy, which limits what your devices reach in the account, is in the README under "Limit what the router can reach".
