# VM bench (`<vm>` in SPEC.md)

The bench builds the router image's files into an official OpenWrt 25.12.6 x86_64 image and boots it in QEMU with KVM, with a stand-in for the modem's AT port and a fake `wwan`.
It checks what the rootfs sandbox (`tests/run-all.sh`) cannot: a real first boot, a boot without the modem, a power cut during the first boot, a factory reset, cron and the persistent log with rotation.
It does not emulate the MF289F hardware, ipq40xx, QMI, the radios or the operator's network.

```
tests/vm/run-all.sh                    # build or reuse the image, run all scenarios one by one
tests/vm/run-all.sh -j 3               # three guests at a time
tests/vm/run-all.sh firstboot cron     # only these scenarios
tests/vm/run-all.sh --overlay DIR      # test another rendered overlay
```

Needs `qemu-system-x86_64`, `/dev/kvm` (user in group `kvm`; `LWVM_NO_KVM=1` runs the guest on the software emulator instead, about 20 times slower, which is how a host without KVM sees the timing of the scenarios), `python3`, `openssl`, `zstd`; no root, no tap or bridge, no network except the downloads of `fetch-deps.sh` and the `uqmi` fetch of `build-image.sh` (below).
`build-image.sh` runs `fetch-deps.sh extra gawk vm` first, so the x86 ImageBuilder, the third-party `.apk` files in `$LW_WORK/dl/extra/` and GNU awk in `$LW_WORK/tools/bin/` are there (firmware `docs/development.md`).
`build-image.sh` also fetches the x86 `uqmi` package from the ImageBuilder's package feeds, to give the guest the same `qmi.sh` as the router image (SPEC R12d), so it needs the network even when the image is cached.
`build.sh --render-only` also needs the x86 rootfs in `$LW_WORK/dl/x86/` (`fetch-deps.sh rootfs`).
One guest has 256 MB and one vCPU and boots in about 13 s.
Full output of each scenario: `$VMWORK/logs/<scenario>.log`.
Per-guest run directory (disk, console log, AT log, markers): `$VMWORK/run/<scenario>[-<part>]/`.
`$VMWORK` is `$LWVM_WORK` or else `$LW_WORK/vm`; `$LW_WORK` defaults to `work/` in the firmware directory.

## Scenarios

| Script | What it proves |
|---|---|
| `10-firstboot.sh` | first boot with the generic profile: the "With `generic.conf`" column of the R7 table (LAN, hostname, timezone, WiFi in uci, WiFi schedule off, wwan as QMI with `modes=lte` and empty APN, firewall zones, `wg0` off, root hash and WiFi key from the password card, SSH, crontab, persistent log), `/etc/lw-build` and the `lw-firstboot` entry (R7b), the data session watcher running idle and silent (R49), the real `sms_tool` talking to the modem stand-in |
| `20-no-modem.sh` | no AT port: LAN and SSH come up anyway (R8), `lw-modem-mode` logs the missing port (R11b) |
| `30-power-cut.sh` | QEMU killed at three points of the first boot (halfway through the image's uci-defaults script, right after it once its changes are synced, 1 s after the last init script); the next start ends with the same `uci export` and root hash as an uninterrupted first boot (R8a); on 25.12.6 fstools wipes an overlay not yet marked ready by init's `done` (START=95), so the two early cuts both restart the first boot from scratch and cannot catch a non-idempotent uci-defaults script |
| `40-reset.sh` | an owner's change survives a reboot (R9); `firstboot -y && reboot` brings back the flash-time `uci export`, an empty log and a new `lw-firstboot` entry (R7, R7b); a power cut 10 s after the reset boot keeps a file written after it (`/overlay/.fs_state` is 2). On x86 the overlay is ext4, so this does not reproduce the UBIFS/jffs2 path of the MF289F |
| `50-cron.sh` | crond at log level 9 logs no job starts (R29a); cron really starts `lw-siglog` (new line in `/tmp/lw-signal.log` with the R28 fields), `wwan-recover` and `lw-sms-clean` |
| `60-log-rotation.sh` | 6000 lines of 200 bytes through `logger`: `/root/openwrt.log.old` appears at 1 MB, no line is lost, both files survive a reboot (R29) |
| `70-modem-mode.sh` | a modem left in auto mode with B7 and SMS store SM gets LTE-only and ME, bands only from `lonewrt.modem.bands` (R11, R11c); on the next boot only the SMS store command goes (R11a) |
| `80-tailscale.sh` | a tailscale image with the real x86 `tailscale` package and a LAN guest (below): the settings of R64 in `tailscale debug prefs`, the zone `tailscale` and its masquerade in nftables (R64a, D149, D155), no nftables table of Tailscale, wg0 next to Tailscale in a second image, `lw-tailscale` states, `link` and `due`, the stop and start of the daemon, `sysupgrade -l` (R72c); with `LWVM_INTERNET=1` also the real CLI against Tailscale's servers (link, a refused key, a key with no internet), with `LWVM_TS_LIVE=1` a sign-in by a person |
| `95-clat.sh` | IPv4 over an IPv6-only session with the real stock `464xlat` and `kmod-nat46` (R76 to R76e, R77): a stand-in protocol `lwvm` (data of an IPv4, a dual-stack or an IPv6 call; for IPv6 alone the DHCPv6 child `wwan_6` as `qmi.sh` makes it) and the operator program `nat64-peer.py` on the host (router advertisements with a /64 and an RDNSS option, DNS64, a NAT64 that answers pings and TCP) as the other end of the wwan NIC; the owner's IPv4 session, a dual-stack one and a dual-stack one with a DHCPv6 child `wwan_6` (mode `dualchild`, a recorder in place of the check) start nothing of the translation (no call of the check, no state, no line; the record of an IPv6-only session that `qmi.sh` leaves is removed when the child is made beside native IPv4); the IPv6-only one gets the operator's own prefix from the DNS64 through `odhcp6c`, the router and the LAN guest reach 8.8.8.8 and an IPv4-only name by ping and TCP, dnsmasq of the router gives the prefix to the LAN, the family check counts the answer over `464-wwan_6_4`, a killed helper comes back at the next run of `wwan-recover`, no DNS64 answer means IPv6 without IPv4 and one log line, the DNS64 that answers late is found by the hotplug of the new session or by the ladder's run, a dual-stack session takes the translation down, `ifdown wwan` alone takes it down too, a new session with the same handles and another operator prefix gets its own helper, a host route to the DNS64 server over another device is refused with one line, and with an unscoped default route over `br-lan` (the lookup with no source says `br-lan`) the query still leaves on `wwan0`: packets are counted per device by an nft table, in this setup and in the plain one; the first packets after a setup may be lost on a slow guest (`LWVM_NO_KVM=1`), which the scenario retries for a bounded time and reports |
| `96-clat-verify.sh` | what `95-clat` left unverified, on an image with WireGuard and Tailscale and with the operator program of `95-clat` extended (below): a WireGuard peer that only IPv4 reaches (a second guest on user-mode networking, one UDP port forwarded from the host; the NAT64 hands the UDP datagrams to it), the largest ping that passes inside the tunnel at link MTU 1500 and 1430, Tailscale's `ip rule` and `ip -6 rule` beside the translation's and what the end of the translation leaves of them, a NAT64 that is gone or has moved (`tick v4fail` of `lw-clat-check`), `ifdown wwan` with no `ifup`, and the operator renumbering the /64 in the middle of the session |

| `96-lan6.sh` | the LAN stops advertising a dead IPv6 default (R74c, R74f, R49i) with the real netifd, odhcpd, `lan6.sh`, the init script and, at the end, the real `lw-linkwatch` over a stand-in for `uqmi` (`tests/linkwatch/stubs/uqmi`): a dual-stack session of the stand-in protocol `lwvm`, the LAN link captured on the host by `lan-ra-peer.py` (every router advertisement is one line with its router lifetime and prefix lifetimes); a loss that netifd sees, with another IPv6 default route present and without it, and a loss that only the watcher's flag shows (the LAN address is not deprecated): a withdrawal advertisement with the old prefix, then the final one with router lifetime 0 and no prefix, then none, also when solicited, and advertisements again when the prefix is back; with the watcher: an IPv6 call disconnected while IPv4 stays (one line, one reload, IPv4 untouched), unreadable settings (nothing), the call connected again (LAN served again) |

`10-firstboot.sh` checks the generic profile's values; an overlay rendered from another profile fails the value checks by design.

## How it is built

`build-image.sh [OVERLAY_DIR]` takes a rendered overlay (default: `build.sh --render-only generic`), adds `tests/vm/overlay/` on top and runs the official x86/64 ImageBuilder (sha256 checked) with the package list of `packages.md` "Included", without `speedtestcpp`, `qrencode` and `libjpeg-turbo-utils` (no VM test uses them), plus the MF289F device defaults that exist for x86_64.
All of them install on x86_64; the third-party ones are `noarch`.
In the ImageBuilder's own `.config` it switches off ext4, tar.gz and EFI images and the GRUB menu delay; packages and kernel stay as released.
The image is cached under `$VMWORK/image/<hash of inputs>/` (the build date in `/etc/lw-build` is not part of the hash), and `image/current` points to the last one.
A given `--overlay DIR` that did not change reuses its image.
The default render does not, because `build.sh --render-only` hashes the reused root password with a new salt every time, so each run builds the image again (about 40 s).
Each guest gets a fresh copy of `disk.img`, which stands in for the flash.

## What is fake, and how

| Router | VM | Decision |
|---|---|---|
| AT port `/dev/ttyUSB2` | second 16550 UART (`/dev/ttyS1`), linked to `/dev/ttyUSB2` by `lw-vm-prep` at START=12, before `lw-modem-mode`; no UART (scenario 20) means no link | the image's scripts and the real `sms_tool` use the port unchanged, with `flock` and `timeout` |
| modem | `modem.py` on the host, behind QEMU's chardev socket: CRLF framing without echo, `+ZSNT`, `+ZNLOCKBAND`, `+CPIN`, `+CIMI`, `+CPMS`, compound `AT+A;+B`, `ERROR` for unknown commands; state in `state.json` survives guest reboots and power cuts like modem NVRAM; knobs in `ctl.json` (`hang`, `cpin`, `delay`, per-command overrides); every command in `at.log` | modem behaviour from the "Modem" requirements of `SPEC.md`; SMS reading answers an empty store |
| `wwan` over QMI | second NIC renamed `wwan0` by `lw-vm-prep`; uci-defaults `zzzz-lw-vm-wwan` (runs after the image's scripts) saves what the image wrote for `wwan` to `/etc/lw-vm/wwan-from-image.uci`, then sets `proto=dhcp`, `device=wwan0` and a default route via the user-net gateway | netifd, firewall and hotplug see a real interface called `wwan` going up and down; there is no `wwan_4`, so the operator DNS is empty |
| IPv6-only operator (`95-clat.sh`) | the stand-in protocol `lwvm` (`overlay/lib/netifd/proto/lwvm.sh`, option `mode` v4, v6 or dual) in place of `qmi` on `wwan`: the call data (`cid_*`, `pdh_*`) and, as `qmi.sh` does, the DHCPv6 child `wwan_6` for an IPv6-only session (the report branch of R73j for dual stack only); the wwan NIC is a unix stream (`vm.py start --wwan-peer`) to `nat64-peer.py` on the host: router advertisements (a /64, an RDNSS option) that `odhcp6c` of `wwan_6` runs on, DNS64 (`ipv4only.arpa`, one IPv4-only name), NAT64 for pings and TCP; switches `dns64` (`off`, `drop`), `nat64` and `ra` are files in its `--ctl` directory, and so are those of `96-clat-verify.sh`: `prefix` (a changed prefix makes the old one stop answering, `nat64-gone` in the log), `ra-prefix` (the operator renumbers: another /64, the old one withdrawn with lifetime 0, an immediate advertisement), `ingress` (`off` lets NAT64 traffic from outside the current /64 through, which the peer drops otherwise like an operator's ingress filter), `mtu` (the link: a packet longer than it is dropped, `toobig` in the log) with `ptb on` (an ICMPv6 Packet Too Big for it) and `udp-forward` (`PORT HOST HOSTPORT`: UDP to PORT of any IPv4 address behind the NAT64 goes to a socket of the host, the answer comes back from that address). Its log has a line per packet it acted on | the real stock `464xlat` proto, `464xlatcfg`, `kmod-nat46`, `odhcp6c`, fw4 and dnsmasq run unchanged; only the modem and the operator are fake. The bench's DNAT of 8.8.8.8 and 1.1.1.1 is deleted in this scenario, and the prefix is not the well-known one (an operator's is not): dnsmasq's rebind protection drops answers in 2001:db8 and in TEST-NET, so the NAT64 prefix is in 3fff:: |
| internet (ping 8.8.8.8 and 1.1.1.1) | QEMU user-net with `restrict=on` (nothing leaves the host); an nft rule in the guest (`table ip lwvm`, set up by `lw-vm-prep`) sends both addresses to the user-net gateway 10.0.3.2, which answers ICMP echo | "online" means: wwan link up and the gateway answers; `vm.py link off` (QEMU `set_link`) cuts it |
| radios | uci-defaults `00-lw-vm-begin` writes `radio0`/`radio1` sections like `wifi config` on the MF289F before the image's scripts run | WiFi is checked in uci; no radio ever comes up |
| LAN, SSH | first NIC on a user-net with the LAN /24 (`lan_ip` taken from the overlay), host port forwarded to `LAN:22` | SSH is checked by its banner; the harness itself drives the guest over the serial console (root shell, no password) |
| power cut | SIGKILL to QEMU at a console marker (`LWVM-MARK ...` printed by VM-only scripts around the image's uci-defaults, and at the end of boot) | data the guest had not written to its disk is lost, data in the host page cache is kept, as on a real cut after the flash write |
| clock for cron | `date -s` back to 75 s before the job's minute | busybox crond starts nothing for a clock that moved back, so each job runs from its own schedule line |
| crond log | scenario 50 switches crond to log level 8 after checking level 9 | only to see which job started; the image's level 9 is checked first |

## Tailscale (`80-tailscale.sh`)

The scenario builds its own images (cached) from profiles it writes to `$VMWORK/profiles/` from `generic.conf` (`TS_ENABLED='1'`, `TS_ADVERTISE_LAN='1'`, LAN `192.168.213.1`, fixed root hash; a second one with `WG_ENABLED='1'` and a made-up key and peer): `build-image.sh` adds `tailscale` and `kmod-tun` when the overlay has `etc/config/tailscale`, and `LWVM_NO_CURRENT=1` keeps such an image out of `image/current`. The ImageBuilder needs the network for the `tailscale` package.

| Part | How |
|---|---|
| LAN guest | `build-lan-guest.sh` builds a second small x86 image from the same ImageBuilder (files in `lan-guest/`: DHCP client, `uhttpd` with a CGI that logs the source of each request to `/tmp/lwvm-src.log`). The router gets a third NIC (`eth2`) joined to the LAN guest's only NIC by a QEMU `-netdev stream` unix socket in the router's run directory (no tap, no root); the scenario puts `eth2` into `br-lan` in place of `eth0`, because the user-net NIC's own DHCP server would make dnsmasq refuse to serve the LAN |
| internet (`LWVM_INTERNET=1`) | the `wwan` NIC without `restrict=on`: NAT to the real internet, through the host's network (the guest can also reach the host's loopback services at 10.0.3.2); the nft rule for 8.8.8.8 and 1.1.1.1 stays; `vm.py link off` still cuts it |
| secrets | the sign-in link goes through a second, unlogged UART (`start --xfer`, `recv`) into a 0600 file, never through the console, whose log QEMU keeps |

```
tests/vm/80-tailscale.sh                         # no internet: SKIP for what needs Tailscale's servers
LWVM_INTERNET=1 tests/vm/80-tailscale.sh         # the real CLI against Tailscale's servers; nobody signs in
LWVM_INTERNET=1 LWVM_TS_LIVE=1 LWVM_TS_PEER=100.x.y.z LWVM_TS_WAIT_ROUTE=1 LWVM_TS_REJOIN=1 tests/vm/80-tailscale.sh
```

`LWVM_TS_LIVE=1` writes the link to `$VMWORK/run/tailscale/ts-link.txt` (0600), prints `LWVM-TS-LINK-READY <path>`, waits up to `LWVM_TS_WAIT_S` (900) for the sign-in and records what it sees in `$VMWORK/run/tailscale/live-report.txt` (0600); `LWVM-TS-STEP <name>` lines mark each step. After the sign-in it keeps both guests up until `$VMWORK/run/tailscale/done` exists or `LWVM_TS_HOLD_S` (1800) passed (the `LWVM-TS-HOLD` line names the URL to open from the laptop: `http://<lan-guest-ip>/cgi-bin/probe`, because only that path logs the source of a request and `/` gives a false SKIP), then checks the LAN guest's log for the source of the requests. Run it directly: `run-all.sh` keeps a scenario's stdout in a log file.

Everything VM-only lives in `tests/vm/overlay/` and in the marker scripts `build-image.sh` writes; none of it is in the router image.

## Files

- `run-all.sh`: builds the image, runs the scenarios, prints PASS/FAIL with durations.
- `build-image.sh`: renders, merges, builds and caches the image.
- `lib.sh`: scenario helpers (guest life cycle, `check`, `gcheck`, `must`, `finish`).
- `vm.py`: one guest: `start`, `wait-ready` (optionally cutting the power on a marker), `sh`, `link`, `recv`, `banner`, `kill`, `stop`.
- `build-lan-guest.sh`, `lan-guest/`: the LAN guest of the Tailscale scenario.
- `modem.py`: the AT modem stand-in.
- `lan-ra-peer.py`: the capture of the router's LAN link for `96-lan6.sh` (it reads the frames of the LAN NIC and logs the router advertisements; a file `rs` in its control directory makes it send a router solicitation).
- `overlay/`: VM-only files for the image.
