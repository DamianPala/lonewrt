#!/usr/bin/env bash
# SPEC R33, R33b: when a card for the profile exists, every build rewrites it from what the image
# holds, so no sequence of profile edits and rebuilds leaves a card that names a password the image
# does not have. Drawn values come back from the old card, a value the profile sets replaces the
# card's, a profile with only a root hash gets a card without a clear root password that says so.
# shellcheck source=tests/build/lib.bash
source "$(dirname "$0")/lib.bash"
scratch card
P=$SCRATCH/profiles
I=$SCRATCH/image
make_profiles "$P"
mkdir -p "$I"
CARD=$I/seq-passwords.txt
UD=etc/uci-defaults/zz-lw-config

# profile WIFI ROOT_PASSWORD HASH: profiles/seq.conf from the fake full profile with these three keys
profile() {
    sed -e "s|^WIFI_KEY=.*|WIFI_KEY='$1'|" -e "s|^ROOT_PASSWORD=.*|ROOT_PASSWORD='$2'|" \
        -e "s|^ROOT_PASSWORD_HASH=.*|ROOT_PASSWORD_HASH='$3'|" "$P/fake-full.conf" >"$P/seq.conf"
}
FAKE_HASH=$(sed -n "s/^ROOT_PASSWORD_HASH='\(.*\)'$/\1/p" "$P/fake-full.conf")

# rebuild: render-only into a fresh directory (the card, if any, is taken from and published to
# $I the way build.sh does) and print the directory
rebuild() {
    local out
    out=$(mktemp -u "$SCRATCH/o.XXXXXX")
    LW_PROFILES=$P LW_IMAGE=$I "$FW/build.sh" --render-only seq "$out" 2>/dev/null ||
        fail "build.sh --render-only seq failed"
    if [ -f "$out-passwords.txt" ]; then
        cmp -s "$out-passwords.txt" "$CARD" 2>/dev/null || cp "$out-passwords.txt" "$CARD"
    fi
    echo "$out"
}
image_value() { sed -n "s/^P_$2='\(.*\)'$/\1/p" "$1/$UD"; }
hash_matches() { [ "$(openssl passwd -6 -salt "$(cut -d'$' -f3 <<<"$2")" "$1")" = "$2" ]; }

# agrees DIR: the card holds the image's WiFi key; its root= line, when there is one, is the
# password of the image's hash; without the line the card says the root password is in the profile
agrees() {
    local wifi hash card_wifi card_root
    [ -f "$CARD" ] || fail "no card"
    wifi=$(image_value "$1" WIFI_KEY)
    hash=$(image_value "$1" ROOT_PASSWORD_HASH)
    card_wifi=$(sed -n 's/^wifi=//p' "$CARD")
    card_root=$(sed -n 's/^root=//p' "$CARD")
    [ "$card_wifi" = "$wifi" ] || fail "the card's wifi= differs from the image's WiFi key"
    if [ -n "$card_root" ]; then
        hash_matches "$card_root" "$hash" || fail "the card's root= is not the password of the image's hash"
    else
        grep -q 'ROOT_PASSWORD_HASH' "$CARD" || fail "a card without root= does not say why"
    fi
}

# 1. the owner sets the WiFi key, root is drawn: a card with the drawn root password
profile ownwifi-123 '' ''
d=$(rebuild)
agrees "$d"
drawn=$(sed -n 's/^root=//p' "$CARD")
[ ${#drawn} -ge 8 ] || fail "no root password drawn"
# 2. ROOT_PASSWORD added: the card follows the profile, nothing stale stays
profile ownwifi-123 ownroot-123 ''
d=$(rebuild)
agrees "$d"
grep -qx 'root=ownroot-123' "$CARD" || fail "the card does not list the new ROOT_PASSWORD"
! grep -qF "$drawn" "$CARD" || fail "the card still names the drawn root password"
grep -qx 'wifi=ownwifi-123' "$CARD" || fail "the card lost the profile's WiFi key"
# 3. ROOT_PASSWORD removed again: the card's root= is reused and the image has its hash
profile ownwifi-123 '' ''
d=$(rebuild)
agrees "$d"
grep -qx 'root=ownroot-123' "$CARD" || fail "the removed ROOT_PASSWORD was not kept from the card"
# 4. only a hash: no clear root password on the card, and the card says so
profile ownwifi-123 '' "$FAKE_HASH"
d=$(rebuild)
agrees "$d"
! grep -q '^root=' "$CARD" || fail "a card for a profile with only a hash has a root= line"
! grep -q 'ownroot-123' "$CARD" || fail "the card still names the old root password"
[ "$(image_value "$d" ROOT_PASSWORD_HASH)" = "$FAKE_HASH" ] || fail "the hash was not used verbatim"
# 5. back to nothing for root: a new password is drawn, since the card has none to reuse
profile ownwifi-123 '' ''
d=$(rebuild)
agrees "$d"
[ ${#drawn} -ge 8 ] && [ -n "$(sed -n 's/^root=//p' "$CARD")" ] || fail "no root password after the hash was removed"

# 6. all drawn, then the owner sets the WiFi key and ROOT_PASSWORD at once
rm -f -- "$CARD"
profile '' '' ''
d=$(rebuild)
agrees "$d"
drawn_wifi=$(sed -n 's/^wifi=//p' "$CARD")
drawn_root=$(sed -n 's/^root=//p' "$CARD")
profile laterwifi-99 laterroot-99 ''
d=$(rebuild)
agrees "$d"
grep -qx 'wifi=laterwifi-99' "$CARD" || fail "the card does not follow the profile's new WiFi key"
grep -qx 'root=laterroot-99' "$CARD" || fail "the card does not follow the profile's new ROOT_PASSWORD"
! grep -qF -e "$drawn_wifi" -e "$drawn_root" "$CARD" || fail "the card still names a drawn password"
# 7. the WiFi key added later, root still drawn: root stays, wifi follows
rm -f -- "$CARD"
profile '' '' ''
d=$(rebuild)
drawn_root=$(sed -n 's/^root=//p' "$CARD")
profile laterwifi-99 '' ''
d=$(rebuild)
agrees "$d"
grep -qx 'wifi=laterwifi-99' "$CARD" || fail "a WiFi key added later is not on the card"
grep -qx "root=$drawn_root" "$CARD" || fail "the drawn root password changed"
# 8. an unchanged profile rebuilt twice keeps the card and the passwords
profile '' '' ''
rm -f -- "$CARD"
d=$(rebuild)
cp -p "$CARD" "$SCRATCH/card-first"
d2=$(rebuild)
d3=$(rebuild)
cmp -s "$CARD" "$SCRATCH/card-first" || fail "an unchanged rebuild changed the card"
[ "$(stat -c %Y "$CARD")" = "$(stat -c %Y "$SCRATCH/card-first")" ] || fail "the card was rewritten"
for x in "$d" "$d2" "$d3"; do
    agrees "$x"
    [ "$(image_value "$x" WIFI_KEY)" = "$(image_value "$d" WIFI_KEY)" ] || fail "the WiFi key changed"
done
# 9. no card and nothing drawn: no card
rm -f -- "$CARD"
profile ownwifi-123 ownroot-123 ''
d=$(rebuild)
[ ! -e "$CARD" ] && [ ! -e "$d-passwords.txt" ] || fail "a card was written with nothing drawn and no old card"
# 10. a cut card with root=x stops the build instead of giving root that password
profile '' '' ''
printf 'ssid=x\nwifi=cardwifi-123\nroot=x\n' >"$CARD"
expect_fail_with "root= must be 8-63 printable ASCII characters" \
    env LW_PROFILES="$P" LW_IMAGE="$I" "$FW/build.sh" --render-only seq "$SCRATCH/cut"
echo ok
