---
name: lonewrt
description: "Build, check and flash a lonewrt OpenWrt image for a ZTE MF289F LTE router from a profile file made in the lonewrt configurator, on the person's Linux machine or in their own private GitHub repository, without ever showing a secret of the profile in the chat. Flashes only after the person's explicit yes, with a backup first. Use when someone says 'build my lonewrt image', 'I have a profile from the configurator', 'build it on GitHub', 'flash the image to my router', 'lonewrt', 'MF289F firmware', or asks to update a router that runs lonewrt. Do not use for editing lonewrt's code (read AGENTS.md instead) or for routers other than the MF289F."
---

# lonewrt: build and flash an image from a profile

lonewrt is OpenWrt firmware for the ZTE MF289F built from one profile file (`KEY='value'` lines, keys in `docs/profile.md`).
The person made the profile in the configurator (`configurator/index.html`, or the hosted copy at https://damianpala.github.io/lonewrt/) and has it as a file.
You lead them from that file to a checked image, and, only when they say yes, to a flashed router.
You are an agent for any harness (Claude Code, Codex, others): the steps use plain shell commands.

## Ground rules

1. **No secret value ever reaches the chat or your tool output** (SPEC R59c).
   The secret keys are `WIFI_KEY`, `ROOT_PASSWORD`, `ROOT_PASSWORD_HASH`, `WWAN_PASSWORD`, `WG_PRIVATE_KEY`, `TG_BOT_TOKEN`, `HC_PING_URL` and `SMS_ADMINS`.
   Never run `cat`, `head`, `tail`, `less`, `grep` (without `-q`), `sed -n p`, `diff` or an editor on the profile, on `image/<name>-passwords.txt` (the password card), or on a backup; never `set -x`; never put a value in a command's arguments.
   Name keys, never values.
   `build.sh` already reports problems by key name only.
2. **Ask the chat only for values that are not secret:** the profile name, the router's address, which way to build (local or GitHub), and, for helping with the configurator, the router name and the country.
   Never ask the person to paste the profile, a password, a token or a key.
   If they paste one anyway, do not repeat it, tell them it is now in the transcript so they should treat that secret as exposed, and carry on from the saved file.
3. **When asked for a password, say which file holds it** (the profile file, or `image/<name>-passwords.txt` when the build drew one) and do not print it.
4. **No flash without a yes** to that flash, every time (R59b). Building, checking and reporting need no yes.
5. **Do not touch** the modem firmware, the WireGuard server, or the router's cron entries and services. A flash replaces the whole image; nothing else is changed on the router.

## Step 1: get the profile file

- No profile yet: send the person to the configurator (link above; or `configurator/index.html` in this repository, opened from disk). Say what to fill: for most people the Wi-Fi name and country, both passwords (`WIFI_KEY` and `ROOT_PASSWORD`; a GitHub run refuses a profile without them), and optionally the SSH key, Telegram, tunnel and bands (explain keys from `docs/profile.md`). They save the file with "Save as a file". Do not ask them to paste its text to you.
- They have a file: ask for its path (a path is not a secret) and for the profile name, which names the files (`<name>-sysupgrade.bin`) and the `profile=` line of `/etc/lw-build`. The name is letters, digits, `-` and `_`, starting with a letter or digit, and not `generic`.
- A profile saved from an older release is fine: the configurator of the release you build loads it, fills new keys and names removed ones. If `build.sh` stops on a missing or unknown key, send the person back to the configurator to load the file and save it again.

## Step 2: put the file in place without reading it

Linux build, from the root of the lonewrt checkout:

```sh
install -m 0600 /path/to/saved-profile.conf profiles/<name>.conf
```

`profiles/*` is ignored by git (R5), so the file cannot be committed by accident.
Do not read it back and do not diff it. If `install` or the path fails, say so and ask for the right path.
For the GitHub way no copy is needed: you send the person's file straight to GitHub (Step 5).

## Step 3: choose the way

Ask which one: "build on this Linux machine" or "build on GitHub" (the person has no Linux machine, or prefers it).
A local build needs Linux x86_64 with the tools of `README.md` ("What you need").
The GitHub way needs a GitHub account, `gh` logged in as that person, and a **private** repository (a public one stops the run before it builds anything).

## Step 4: local build

```sh
export LW_WORK=<work folder>      # only if the person keeps the dependencies somewhere else
./fetch-deps.sh                   # once; about 530 MB into work/
./build.sh <name>                 # image/<name>-sysupgrade.bin, image/<name>.manifest
tests/build/run.sh --quick        # code checks of this release; add tests/run-all.sh when time allows
```

`build.sh` ends with a `sha256sum` line for the image. Then make the report (Step 6).

A failed `build.sh` or test is reported with its own message (it names keys, never values) and **you offer no flash**.
Example: an empty `LAN_IP` stops the build naming `LAN_IP`; report "the build failed on LAN_IP" and offer to fix it through the configurator.

## Step 5: GitHub build (R59g, D120)

Needed: `gh auth status` shows the person's own login. Use only that login.

1. **The repository.** Ask first: "I will create a private repository `<owner>/<repo>` from the template `DamianPala/lonewrt-build` in your account. Yes?" Only after a yes:
   ```sh
   gh repo create <repo> --private --template DamianPala/lonewrt-build
   ```
   If the person already has such a repository, use it and check it is private: `gh repo view <owner>/<repo> --json isPrivate -q .isPrivate` must print `true`.
2. **The secret goes in without passing through you.** Either the person pastes the file's text into GitHub (Settings > Secrets and variables > Actions > New repository secret, name `LW_PROFILE`), or you run, with the file as stdin and nothing else:
   ```sh
   gh secret set LW_PROFILE --repo <owner>/<repo> < /path/to/saved-profile.conf
   ```
   The arguments and the output hold no value. On Windows PowerShell, which has no `<`, use `Get-Content -Raw <file> | gh secret set LW_PROFILE --repo <owner>/<repo>` (not checked).
3. **The version.** The run builds the lonewrt release you name. Use the version the configurator page showed ("For lonewrt release ..."), because a profile made for another release may be refused. Without a version the run takes the newest release.
4. **Start and watch.** Never set the `test` input with a real profile (it only exists for a public repository and ignores the secret):
   ```sh
   gh workflow run build.yml --repo <owner>/<repo> -f version=<version> -f name=<name>
   sleep 10   # a new repository may need a few seconds before the workflow is known
   run_id=$(gh run list --repo <owner>/<repo> --workflow build.yml --limit 1 --json databaseId -q '.[0].databaseId')
   gh run watch "$run_id" --repo <owner>/<repo> --exit-status
   ```
   A failed run stops with a message naming the problem (a missing secret, a key, an empty password, a failed test) and leaves no artifact: report that message, offer no flash.
5. **Download and check.** The artifact is `lonewrt-<name>-<version>` and stays 7 days:
   ```sh
   gh run download "$run_id" --repo <owner>/<repo> -n lonewrt-<name>-<version> -D <folder outside any git repo>
   sha256sum <folder>/<name>-sysupgrade.bin
   gh run view "$run_id" --repo <owner>/<repo> --log | grep -oE '[0-9a-f]{64}  [^ ]*-sysupgrade\.bin'
   ```
   The second hash, from the build step of the run's log, must equal the first. The run's summary page (`gh run view "$run_id" --repo <owner>/<repo> --web`) also names the sha256, the version and the commit; if the log line is not there, ask the person to read that sha256 from the summary and compare. A mismatch means do not flash.

## Step 6: the report (R59a)

End every build with a short report in the chat:

- passed or failed, and for a failure the message of `build.sh` or of the test (key names only);
- the release version and the profile name of the image (local: the `VERSION` file and `<name>`; GitHub: from the artifact name and the run's summary; the image's `/etc/lw-build` holds the same);
- the sha256 of `<name>-sysupgrade.bin`, and where the image is;
- when `image/<name>-passwords.txt` exists (a local build with a drawn password), say that the card is there and name the file; never its content. A GitHub run writes no card, because both passwords are in the profile.

Then ask whether they want it flashed. A flash is a separate question; do not bundle it with "build".

## Step 7: flash (R59b, D101)

Everything here waits for the person's explicit yes to **this** flash ("flash it", "yes, flash"). A yes to the build or to an earlier flash does not count.
A bad image means opening the case and a serial console (`docs/development.md`, "Recovery"), so every gate below is a stop, not a warning.

**7.0 Access.** Ask for the router's address. Ask whether it is the router's LAN address or an address reached through the WireGuard tunnel.
Run `ssh -o BatchMode=yes root@<router> true`. If it fails, the person has no key login for you: do not ask for the router password. Give them the commands of `README.md` ("Quick start") to run themselves, or ask them to add their SSH key and try again.
The flash cuts the connection; do not run it over the router's own Wi-Fi from the same laptop unless the person accepts losing the link.

**7.1 Tunnel limit (R59e, D121).** Over the tunnel, a wrong `WG_*`, `WWAN_*` or `LTE_BANDS` value cuts the router off until someone is on site.
So when the address is a tunnel address, compare the profile with the router's current settings first. This prints key names only:

```sh
profile=profiles/<name>.conf router=root@<router>
map='WG_ENABLED network.wg0.disabled
WG_PRIVATE_KEY network.wg0.private_key
WG_ADDRESS network.wg0.addresses
WG_PEER_PUBLIC_KEY network.wg_server.public_key
WG_ENDPOINT_HOST network.wg_server.endpoint_host
WG_ENDPOINT_PORT network.wg_server.endpoint_port
WG_ALLOWED_IPS network.wg_server.allowed_ips
WG_KEEPALIVE network.wg_server.persistent_keepalive
WWAN_APN network.wwan.apn
WWAN_AUTH network.wwan.auth
WWAN_USERNAME network.wwan.username
WWAN_PASSWORD network.wwan.password
LTE_BANDS lonewrt.modem.bands'
norm() { tr ',' ' ' | tr -s ' ' | sed 's/^ //; s/ $//'; }
changed=
while read -r key opt; do
    want=$(sed -n "s/^[[:space:]]*$key='\(.*\)'[[:space:]]*\$/\1/p" "$profile" | head -n 1 | norm)
    have=$(ssh -n -o BatchMode=yes "$router" "uci -q get $opt" | norm)
    if [ "$key" = WG_ENABLED ]; then if [ "$have" = 1 ]; then have=0; else have=1; fi; fi
    [ "$want" = "$have" ] || changed="$changed $key"
done <<EOF2
$map
EOF2
echo "keys that differ:${changed:- none}"
```

If the profile is not on this machine (the GitHub way), the person saves the downloaded profile file to `profiles/<name>.conf` as in Step 2 first, or compares in the configurator themselves.
If any key differs: stop before the backup, name the keys, and say why. Continue only after the person says that **someone is at the router**. A differing key can also be a false alarm (a value the router has changed in LuCI, a different spelling of a list); the rule errs on the side of asking.
On the LAN address, or with no differing key, there is no extra condition.

**7.2 Backup first** (on the person's machine, outside any git repo, because it holds the router's keys and passwords):

```sh
b=$HOME/lonewrt-backups/<router>-$(date +%Y%m%d-%H%M); umask 077; mkdir -p "$b"
ssh root@<router> 'sysupgrade -b /tmp/lw-backup.tar.gz'
scp -O root@<router>:/tmp/lw-backup.tar.gz "$b/backup.tar.gz"
scp -O -r root@<router>:/root "$b/root"                 # logs and SMS archive
tar -tzf "$b/backup.tar.gz" >/dev/null                   # the archive reads back
```

Any failure here stops the flash. Tell the person where the backup is.

**7.3 Copy and check:**

```sh
scp -O image/<name>-sysupgrade.bin root@<router>:/tmp/fw.bin    # or the artifact's path
ssh root@<router> 'sha256sum /tmp/fw.bin'                        # must equal the report's sha256
ssh root@<router> 'sysupgrade -T /tmp/fw.bin'                    # silent and exit 0 means the image is accepted
```

A failed copy, a different sha256 or a failed `sysupgrade -T` stops here: report it, do **not** run `sysupgrade -n`.

**7.4 Flash.** Only now, one call in the background so that a dropped SSH session does not matter:

```sh
ssh root@<router> 'sysupgrade -n /tmp/fw.bin </dev/null >/tmp/lw-flash.log 2>&1 &'
```

`-n` drops the old settings: the image sets everything from the profile at its first start.
The router is back after about 100 s and LTE and the tunnel about 70 s later. Tell the person; do not poll in a loop for longer than a few minutes.
A lost connection during the flash is expected at first. If the router does not come back, report it with the recovery note of `README.md`: flash any other OpenWrt sysupgrade image the same way and restore the backup with `sysupgrade -r`; this model has no failsafe, and a broken image means the case and a serial console (`docs/development.md`, "Recovery"). Do not retry the flash.

**7.5 After the flash.**
- The image has a new SSH host key unless the profile's folder holds host keys, so `ssh` will complain (R55). Show the new fingerprint, with `ssh-keyscan -t ed25519 <router> 2>/dev/null | ssh-keygen -lf -`, and **ask** before removing the old entry with `ssh-keygen -R <router>`.
- When the router answers with the key login, check `ssh root@<router> cat /etc/lw-build` (version and profile name, no secrets) against the report and say so. If you cannot log in, the person checks it in LuCI.
- Point them to "After flashing" in `README.md` for the Wi-Fi, LuCI and reset hints; the password is in the profile file, not in the chat.

## Limits

- A flash of the wrong model or an image from another source is the person's risk; flash only images from this skill's build.
- No modem firmware, no WireGuard server changes, no new cron, loops or services on the router.
- Windows: `ssh` and `scp` ship with Windows; the router's dropbear has no SFTP server, so `scp -O` is probably needed, as above. Neither that nor the PowerShell form of `gh secret set` has been checked. Prefer a WSL or Linux shell for the flash when in doubt.
- Over the tunnel the check of Step 7.1 is the only guard against a wrong tunnel or band field. When unsure, ask for someone at the router.
- The generic image (`./build.sh generic`) holds no secrets and needs no profile file; the flash steps are the same.

## Example, local

> Person: I have a profile from the configurator at ~/Downloads/home.conf. Build on my laptop.
> You: What should the profile be called? (letters, digits, - and _.) ... `install -m 0600 ~/Downloads/home.conf profiles/home.conf`, `./fetch-deps.sh`, `./build.sh home`, `tests/build/run.sh --quick`.
> You: Build passed, release 0.1.0, profile `home`, sha256 `<64 hex>`, image `image/home-sysupgrade.bin`. Both passwords are in your profile file `~/Downloads/home.conf`; I did not open it. Flash it now?
> Person: Yes, flash it. It is on the LAN at 192.168.1.1.
> You: Backup to `~/lonewrt-backups/...`, copy, sha256 equal, `sysupgrade -T` passed. Flashing, back in about 100 s.

## Example, GitHub

> Person: Build it on GitHub. File is ~/Downloads/home.conf, the page said 0.1.0.
> You: I will create a private repository `<you>/lonewrt-build` from the template `DamianPala/lonewrt-build`, and send your file to its secret `LW_PROFILE` without reading it. Yes?
> Person: Yes.
> You: `gh repo create lonewrt-build --private --template DamianPala/lonewrt-build`, `gh secret set LW_PROFILE --repo <you>/lonewrt-build < ~/Downloads/home.conf`, `gh workflow run build.yml ... -f version=0.1.0 -f name=home`, watch, download `lonewrt-home-0.1.0`, compare sha256 with the run's log. Report as in Step 6, then ask about the flash.
