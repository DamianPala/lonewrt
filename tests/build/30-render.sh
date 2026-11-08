#!/usr/bin/env bash
# Rendered overlays without ImageBuilder: the generic one carries no private or fake-profile value
# (SPEC R4, R4a), the fake full one carries its values and SSH key files, /etc/lw-build names the
# profile and a reproducible digest of src/ (R7b), the password card follows R33 and R33a.
# Leaves tests/.out/render/{generic,fake-full} for the first-boot tests (tests/run-all.sh firstboot).
# shellcheck source=tests/build/lib.bash
source "$(dirname "$0")/lib.bash"
scratch render
P=$SCRATCH/profiles
make_profiles "$P"

rm -rf -- "$RENDER"
mkdir -p "$RENDER"
"$FW/build.sh" --render-only generic "$RENDER/generic" 2>/dev/null
LW_PROFILES=$P "$FW/build.sh" --render-only fake-full "$RENDER/fake-full" 2>/dev/null
D=$RENDER/generic
F=$RENDER/fake-full
UD=etc/uci-defaults/zz-lw-config

# R4, R4a on the overlay; the image test repeats this on the unpacked rootfs
assert_absent "$D" "${LW_VALUES[@]}" "${FAKE_VALUES[@]}"
assert_absent "$F" "${LW_VALUES[@]}"
assert_present "$F" "${FAKE_VALUES[@]}"
[ ! -e "$D/etc/dropbear" ] || fail "generic overlay has /etc/dropbear"
! grep -rqE '@[A-Z][A-Z0-9_]*@' "$D" "$F" || fail "unfilled placeholder left"
# The project prefix is lw (uci package lonewrt): no overlay path or reference keeps the old rh prefix
old_paths=$(find "$D" "$F" -mindepth 1 -printf '%P\n' | grep -E '(^|[-_./])rh([-_./]|$)' || :)
[ -z "$old_paths" ] || fail "overlay paths with the old rh prefix: $old_paths"
! grep -rqE '(^|[^A-Za-z0-9])(rh([^A-Za-z0-9]|$)|RH_)' "$D" "$F" ||
    fail "overlay content refers to the old rh prefix"

# File modes: secrets and the crontab 0600, the uci-defaults script 0700, scripts executable
for f in authorized_keys dropbear_ed25519_host_key dropbear_rsa_host_key; do
    [ "$(stat -c %a "$F/etc/dropbear/$f")" = 600 ] || fail "etc/dropbear/$f is not 0600"
    cmp -s "$F/etc/dropbear/$f" "$FIX/fake-full/$f" || fail "etc/dropbear/$f differs from the profile"
done
[ "$(stat -c %a "$D/$UD")" = 700 ] || fail "$UD is not 0700"
[ "$(stat -c %a "$D/etc/crontabs/root")" = 600 ] || fail "crontab is not 0600"
[ "$(stat -c %a "$D/etc/init.d/lw-firstboot")" = 755 ] || fail "lw-firstboot is not executable"
[ "$(stat -c %a "$D/usr/lib/lw/lw-apn")" = 755 ] || fail "lw-apn is not executable"
[ "$(stat -c %a "$D/usr/lib/lw/common.sh")" = 644 ] || fail "common.sh is not 0644"
for f in usr/sbin/lw-heartbeat etc/hotplug.d/ntp/30-lw-nlbwmon; do
    [ "$(stat -c %a "$D/$f")" = 755 ] || fail "$f is not executable"
done
# Directory modes become those of /, /etc, /usr/sbin ... in the image (cp -p in ImageBuilder)
bad=$(find "$D" "$F" -type d ! -perm 755 ! -path "$F/etc/dropbear")
[ -z "$bad" ] || fail "overlay dirs not 0755: $bad"
[ "$(stat -c %a "$F/etc/dropbear")" = 700 ] || fail "etc/dropbear is not 0700"
# Every file under the overlay with a shell shebang, plus sourced dirs, goes through sh -n (R6)
S=$SCRATCH/src-syntax
for f in usr/lib/lw/lw-apn usr/lib/lw/common.sh etc/hotplug.d/iface/99-auto-apn-at; do
    rm -rf -- "$S"
    cp -a "$FW/src" "$S"
    printf '\nif true; then\n' >>"$S/files/$f"
    expect_fail_with "syntax error in $f" env LW_SRC="$S" "$FW/build.sh" --render-only generic \
        "$SCRATCH/syntax-out"
done

# R7b: profile name, build date and the digest of src/ (sorted relative paths, NUL, sha256 of content)
digest=$(cd "$FW/src" && find . -type f -printf '%P\n' | LC_ALL=C sort | while read -r rel; do
    printf '%s\0%s\n' "$rel" "$(sha256sum <"$rel" | cut -d' ' -f1)"
done | sha256sum | cut -d' ' -f1)
grep -qx "profile=generic" "$D/etc/lw-build" || fail "lw-build lacks the profile name"
grep -qE '^built=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$D/etc/lw-build" || fail "lw-build lacks the date"
grep -qx "src_sha256=$digest" "$D/etc/lw-build" || fail "lw-build digest is not $digest"
grep -qx "src_sha256=$digest" "$F/etc/lw-build" || fail "fake-full digest differs from generic"

# R33: the fake profile sets both passwords, so it gets no card; the generic one gets a 0600 card
[ ! -e "$F-passwords.txt" ] || fail "a profile with both passwords got a card"
card=$D-passwords.txt
[ "$(stat -c %a "$card")" = 600 ] || fail "card is not 0600"
grep -qx 'ssid=OpenWrt-LTE' "$card" || fail "card lacks ssid="
wifi=$(sed -n 's/^wifi=//p' "$card")
root=$(sed -n 's/^root=//p' "$card")
[ ${#wifi} -ge 8 ] && [ ${#root} -ge 8 ] || fail "card lacks wifi= or root="
grep -qxF "P_WIFI_KEY='$wifi'" "$D/$UD" || fail "image WiFi key is not the card's"
hash=$(sed -n "s/^P_ROOT_PASSWORD_HASH='\(.*\)'$/\1/p" "$D/$UD")
salt=$(cut -d'$' -f3 <<<"$hash")
[ "$(openssl passwd -6 -salt "$salt" "$root")" = "$hash" ] || fail "root hash does not match the card"

# R33a: hints under the passwords
for hint in 'https://192.168.1.1' certificate 'A reset with the button' PIN APN 'LTE only' \
    'Scheduled Tasks' /root/sms-archive/ 'Country Code'; do
    grep -qF -- "$hint" "$card" || fail "card lacks the hint '$hint'"
done

# R33: an existing card in image/ gives the same passwords to the next build
I=$SCRATCH/image
mkdir -p "$I"
printf 'ssid=old\nwifi=keep-this-wifi\nroot=keep-this-root\n' >"$I/generic-passwords.txt"
LW_IMAGE=$I "$FW/build.sh" --render-only generic "$SCRATCH/again" 2>/dev/null
grep -qxF "P_WIFI_KEY='keep-this-wifi'" "$SCRATCH/again/$UD" || fail "card WiFi key not reused"
grep -qx 'root=keep-this-root' "$SCRATCH/again-passwords.txt" || fail "card root password not reused"
grep -qx 'ssid=OpenWrt-LTE' "$SCRATCH/again-passwords.txt" || fail "card ssid not taken from the profile"
echo ok
