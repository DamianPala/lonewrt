#!/usr/bin/env bash
# Real ImageBuilder builds (about 1,5 min each, no network): the generic image twice into a scratch
# image/ (R33: the second build keeps the card and its passwords; the real image/ is not touched),
# its rootfs free of private and fake-profile values (R4, R4a) and its manifest against packages.md (R2);
# then the fake full profile into another scratch image/ whose rootfs carries the profile's values
# and SSH keys (R7, R31), the heartbeat line (R42) and the nlbwmon hotplug script (R44a).
# shellcheck source=tests/build/lib.bash
source "$(dirname "$0")/lib.bash"
scratch images
UD=etc/uci-defaults/zz-lw-config

# packages_in TABLE: backticked package names in the first column of a packages.md table (names
# inside parentheses are dependencies pulled in, not packages to ask for)
packages_in() {
    # shellcheck disable=SC2016  # literal backticks of the markdown table
    awk -v want="$1" '/^## /{on = index($0, want) > 0; next} on && /^\| `/' "$FW/packages.md" |
        cut -d'|' -f2 | sed 's/([^)]*)//g' | grep -o '`[^`]*`' | tr -d '`'
}

# check_manifest FILE: every "Included" package installed, none of "Left out" (SPEC R2)
check_manifest() {
    local installed pkg
    installed=$(cut -d' ' -f1 "$1")
    while read -r pkg; do
        grep -qx -- "$pkg" <<<"$installed" || fail "manifest lacks $pkg"
    done < <(packages_in Included)
    while read -r pkg; do
        while read -r name; do
            # shellcheck disable=SC2053  # the table uses globs such as collectd*
            if [[ $name == $pkg ]]; then fail "manifest has rejected $name"; fi
        done <<<"$installed"
    done < <(packages_in 'Left out')
}

# build.sh installs exactly the "Included" table minus the default-set row
want=$(packages_in Included | grep -vxE 'uqmi|kmod-.*|wpad-basic-mbedtls|firewall4|dnsmasq|dropbear' | sort)
have=$(sed -n '/^PACKAGES=(/,/^)/p' "$FW/build.sh" | sed '1d;$d' | tr ' ' '\n' | sed '/^$/d' | sort)
[ "$want" = "$have" ] || fail "build.sh PACKAGES differ from packages.md: $(diff <(echo "$want") <(echo "$have") | tr '\n' ' ')"

# Generic image, twice; the card and its passwords stay the same (R33)
DI=$SCRATCH/generic-image
mkdir -p "$DI"
LW_IMAGE=$DI "$FW/build.sh" generic >/dev/null
card=$DI/generic-passwords.txt
cp -p "$card" "$SCRATCH/card-first"
LW_IMAGE=$DI "$FW/build.sh" generic >/dev/null
cmp -s "$card" "$SCRATCH/card-first" || fail "second build changed generic-passwords.txt"
[ "$(stat -c %Y "$card")" = "$(stat -c %Y "$SCRATCH/card-first")" ] || fail "second build rewrote the card"
check_manifest "$DI/generic.manifest"

mkdir -p "$SCRATCH/generic"
unpack_image "$DI/generic-sysupgrade.bin" "$SCRATCH/generic"
R=$SCRATCH/generic/rootfs
assert_absent "$R" "${LW_VALUES[@]}" "${FAKE_VALUES[@]}"
[ -z "$(ls -A "$R/etc/dropbear")" ] || fail "generic image has files in /etc/dropbear"
[ "$(stat -c %a "$R" "$R/etc" "$R/usr/sbin" | sort -u)" = 755 ] || fail "/, /etc or /usr/sbin not 0755"
for f in "$UD" etc/init.d/lw-firstboot etc/lw-build etc/config/lonewrt etc/config/watchcat \
    etc/crontabs/root usr/lib/lw/common.sh etc/init.d/lw-notify usr/sbin/lw-notify \
    usr/sbin/lw-heartbeat etc/hotplug.d/ntp/30-lw-nlbwmon usr/lib/lw/devices.sh usr/lib/lw/reboot.sh; do
    [ -e "$R/$f" ] || fail "generic image lacks /$f"
done
# ImageBuilder enables every rc.common script of FILES in the image itself, so the services start
# on the very first boot (procd globs /etc/rc.d before S10boot runs uci-defaults) and after a reset
for s in lw-modem-mode lw-firstboot watchcat cron nlbwmon; do
    compgen -G "$R/etc/rc.d/S[0-9][0-9]$s" >/dev/null || fail "image does not enable $s in /etc/rc.d"
done
# Our set_up_bandz.sh replaces the package's, which talked to the modem inside S10boot (R8, R12a)
cmp -s "$R/etc/uci-defaults/set_up_bandz.sh" "$FW/src/files/etc/uci-defaults/set_up_bandz.sh" ||
    fail "image /etc/uci-defaults/set_up_bandz.sh is not the overlay's"
! grep -v '^#' "$R/etc/uci-defaults/set_up_bandz.sh" | grep -q modemband || fail "set_up_bandz.sh still calls the modem"
# Notifications off in the generic image: the crontab of the sources, no balance cron line, empty keys (R38a)
cmp -s "$R/etc/crontabs/root" "$FW/src/files/etc/crontabs/root" || fail "generic image crontab differs"
grep -qx "P_TG_BOT_TOKEN=''" "$R/$UD" || fail "generic image has a bot token"
grep -qx "P_HC_PING_URL=''" "$R/$UD" || fail "generic image has a heartbeat address"
wifi=$(sed -n 's/^wifi=//p' "$card")
root=$(sed -n 's/^root=//p' "$card")
grep -qxF "P_WIFI_KEY='$wifi'" "$R/$UD" || fail "image WiFi key is not the card's"
hash=$(sed -n "s/^P_ROOT_PASSWORD_HASH='\(.*\)'$/\1/p" "$R/$UD")
[ "$(openssl passwd -6 -salt "$(cut -d'$' -f3 <<<"$hash")" "$root")" = "$hash" ] ||
    fail "image root hash does not match the card"

# Fake full profile into a scratch image/ (nothing of it lands in the real image/)
P=$SCRATCH/profiles
I=$SCRATCH/image
make_profiles "$P"
LW_PROFILES=$P LW_IMAGE=$I "$FW/build.sh" fake-full >/dev/null
[ ! -e "$I/fake-full-passwords.txt" ] || fail "a profile with both passwords got a card"
# ImageBuilder's build_dir keeps no copy of the profile's rootfs or image (SPEC D15)
assert_absent "$LW_WORK/ib" "${FAKE_VALUES[@]}"
check_manifest "$I/fake-full.manifest"
mkdir -p "$SCRATCH/fake"
unpack_image "$I/fake-full-sysupgrade.bin" "$SCRATCH/fake"
R=$SCRATCH/fake/rootfs
assert_present "$R" "${FAKE_VALUES[@]}"
assert_absent "$R" "${LW_VALUES[@]}"
grep -qxF '0 10 * * 1 /usr/sbin/lw-notify balance' "$R/etc/crontabs/root" ||
    fail "full image crontab lacks the balance cron line"
grep -qxF '*/5 * * * * /usr/sbin/lw-heartbeat' "$R/etc/crontabs/root" ||
    fail "full image crontab lacks the heartbeat line"
[ -x "$R/usr/sbin/lw-heartbeat" ] && [ -x "$R/etc/hotplug.d/ntp/30-lw-nlbwmon" ] ||
    fail "full image lacks an executable heartbeat or nlbwmon hotplug script"
[ -x "$R/etc/hotplug.d/iface/30-nlbwmon" ] || fail "full image lacks the nlbwmon package's own hotplug script"
for f in authorized_keys dropbear_ed25519_host_key dropbear_rsa_host_key; do
    [ "$(stat -c %a "$R/etc/dropbear/$f")" = 600 ] || fail "/etc/dropbear/$f is not 0600 in the image"
done
[ "$(stat -c %a "$I/fake-full-sysupgrade.bin")" = 600 ] || fail "image file is not 0600"
echo "ok: $(stat -c %s "$DI/generic-sysupgrade.bin") bytes (scratch image, removed with the test)"
