# Remote access with Tailscale

Tailscale joins your own devices into one private network, so you reach the router's settings page (LuCI) and SSH from your laptop or phone, with no server of your own.
Tailscale is optional. The image includes it only if you set `TS_ENABLED='1'` in your profile.
Use the [account's access policy](#limit-what-the-router-can-reach) to limit what the router can reach.

## Before the build

1. Make a free account at tailscale.com.
2. Install the Tailscale app on your laptop and your phone, and sign in with the same account. Another account is another private network, and the router will not show up in yours.
3. Set `TS_ENABLED` to `1` in the configurator (group Tailscale) or in the profile as `TS_ENABLED='1'`. Then build and flash using the [Linux quick start](../README.md#quick-start) or [the browser and GitHub](../README.md#build-without-linux).

## Sign in

After the flash, the bot sends a sign-in link to your Telegram chat, once for each flash without kept settings and each button reset.
Open the link on your phone or laptop and sign in.
Without Telegram, send `tailscale` by SMS to the router's SIM, or run `lw-tailscale link` over SSH; both give you a link.
If the link is old, send `/tailscale` in the chat for a new one.

Do not run a bare `tailscale up` on the router: it can switch on the firewall and DNS settings that the image keeps off.

Then turn off key expiry for the router, or its sign-in ends after 180 days.
On the Machines page of the admin console, open the menu at the right of the router's row and choose **Disable Key Expiry**.
The bot warns you 14 days before the date when key expiry is still on.

## Connect

- In a browser: `https://` followed by `HOSTNAME` of your profile, for example `https://lte-router`. This opens LuCI. The browser warns about the certificate, as described in [After flashing](../README.md#after-flashing).
- Over SSH: `ssh root@<HOSTNAME>`.

This needs MagicDNS, which is on by default; the DNS page of the admin console shows it.

## The router's network (optional)

With `TS_ADVERTISE_LAN` set to `1`, your devices can also reach the devices on the router's network, such as a camera.

1. Approve the route once: on the Machines page, open the router and its **Subnets** section, select the route and save.
2. On Linux, run `sudo tailscale set --accept-routes`. Android, iOS, macOS and Windows pick the route up on their own.
3. If your home network is `192.168.0.x` or `192.168.1.x`, it clashes with the router's network. The build and the configurator warn about it, and the configurator can set another `LAN_IP`.
   A device that is itself on a network with the router's addresses, for example a laptop on the router's own Wi-Fi, must not accept the route: its traffic to that network would go through Tailscale, and it can lose the local network. On Linux, turn it off with `sudo tailscale set --accept-routes=false`, or give the router a rare network such as `192.168.213.1`.
4. Devices on the router's network see the router's address, not yours, because the router passes your traffic on under its own address.

## Reset or reflash

A button reset, or a flash without "Keep settings", gives the router a new identity in Tailscale, and the old entry stays in your account.
Before you do it, remove the router's entry on the Machines page of the admin console.
If the router then comes up with a number at the end of its name (`lte-router-1`), remove the old entry and rename the new one on that page.
A router added again with a link has no tag, so give it the tag again, see [Limit what the router can reach](#limit-what-the-router-can-reach).
After a flash that keeps settings, a router that is not added yet sends no link by itself, so send `/tailscale`.

To update the image and keep the router in your account, with everything else set from the profile, keep only the Tailscale files. The agent skill does this by itself; by hand, after copying the image to `/tmp/fw.bin` as for any flash:

```sh
ssh root@<router> 'tar -czf /tmp/lw-ts-keep.tar.gz -C / etc/tailscale'
ssh root@<router> 'sysupgrade -f /tmp/lw-ts-keep.tar.gz /tmp/fw.bin'
```

## Auth key (optional)

To add the router without a click, put a key into the profile as `TS_AUTHKEY`.
Make it on the Keys page of the admin console with **Generate auth key**, and set:

- **Reusable** off and **Ephemeral** off.
- **Tags**: optional. A tagged device has key expiry off by default, so a tag replaces the step above.
- **Pre-approved**: on when device approval is on in your account.
- **Expiry**: a day or more and at most 90 days, and later than the day of the flash.

The key must start with `tskey-auth-`. Keys starting with `tskey-api-` or `tskey-client-` are for API tools; the build refuses them.
The router uses the key once. After a reset or a later flash, the bot sends a link again.
The key sits in the image like the other profile secrets, so keep the image private.

## Safety

The sign-in link is a key.
Whoever signs in with it first adds the router to that account, and every device of the account can reach the router's settings page and SSH (both still ask for the login).
Send the link only to the person who manages the router.
If the router ended up in the wrong account, a button reset puts it back to a fresh state, and the bot sends a new link.

## Limit what the router can reach

By default every device in a Tailscale account reaches every other device.
So a stolen router with root could join your account and reach your laptop and phone, and the router's firewall does not stop that, because root can change the firewall.
The account's access policy does, so set it up as follows.

1. On the Access controls page of the admin console, replace the policy with the one below and save it. If you changed the policy before, add these parts to yours instead. The policy has to come first, because a tag can be applied only when the policy's `tagOwners` names it.
2. Give the router the tag `tag:lonewrt`: on the Machines page, open the router's menu and choose **Edit tags**, or add the tag to its auth key.
3. Check that your laptop still opens the router's settings page.

```json
{
  "tagOwners": {
    "tag:lonewrt": ["autogroup:admin"]
  },
  "acls": [
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["autogroup:member:*"]
    },
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["tag:lonewrt:22,80,443"]
    }
  ]
}
```

Your devices reach the router's SSH (22) and its settings page (80 and 443), and they still reach each other.
No rule has the router as its source, so the router starts no connection into your account.
The router's own firewall blocks those connections too, but root can change that firewall, while the policy stays in your account.
If `TS_ADVERTISE_LAN` is `1`, add the router's network with its mask to the second rule, for a `LAN_IP` of `192.168.5.1` as `"dst": ["tag:lonewrt:22,80,443", "192.168.5.0/24:*"]`.

A tag that comes with the auth key also turns key expiry off. A tag added later with **Edit tags** leaves key expiry as it was, so turn it off as described under [Sign in](#sign-in).

## Cost

The Tailscale packages make the image about 18 MB.
The free space on the router drops from about 12.5 MiB to about 4 to 6 MiB, so install few extra packages later.
How much data Tailscale uses while idle is not measured yet; on a prepaid SIM it counts against your data.
