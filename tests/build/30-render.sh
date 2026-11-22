#!/usr/bin/env bash
# Rendered overlays without ImageBuilder: the generic one carries no private or fake-profile value
# (SPEC R4, R4a), the fake full one carries its values and SSH key files, /etc/lw-build names the
# profile and a reproducible digest of src/ (R7b), the password card follows R33 and R33a. Tailscale
# (R63, R64b): the generic overlay is src/files and nothing else, a tailscale overlay adds the tree
# src/files-tailscale and the auth key in one file of mode 0600.
# Leaves tests/.out/render/{generic,fake-full,ts-plain,ts-key,ts-lan,debug-plain} for the first-boot
# tests (tests/run-all.sh firstboot).
# shellcheck source=tests/build/lib.bash
source "$(dirname "$0")/lib.bash"
scratch render
P=$SCRATCH/profiles
make_profiles "$P"

rm -rf -- "$RENDER"
mkdir -p "$RENDER"
"$FW/build.sh" --render-only generic "$RENDER/generic" 2>/dev/null
LW_PROFILES=$P "$FW/build.sh" --render-only fake-full "$RENDER/fake-full" 2>/dev/null
# ts_profile NAME SED...: generic.conf with the sed edits, rendered into $RENDER/NAME
ts_profile() {
    local n=$1
    shift
    sed "$@" "$P/generic.conf" >"$P/$n.conf"
    LW_PROFILES=$P "$FW/build.sh" --render-only "$n" "$RENDER/$n" 2>/dev/null
}
on="s/^TS_ENABLED=.*/TS_ENABLED='1'/"
ts_profile ts-plain -e "$on"
ts_profile ts-key -e "$on" -e "s|^TS_AUTHKEY=.*|TS_AUTHKEY='$FAKE_TS_AUTHKEY'|"
ts_profile ts-lan -e "$on" -e "s/^TS_ADVERTISE_LAN=.*/TS_ADVERTISE_LAN='1'/" \
    -e "s/^LAN_IP=.*/LAN_IP='192.168.5.1'/" -e "s/^HOSTNAME=.*/HOSTNAME='ts-router'/" \
    -e "s/^LOG_LEVEL=.*/LOG_LEVEL='debug'/"
ts_profile debug-plain -e "s/^LOG_LEVEL=.*/LOG_LEVEL='debug'/"
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
done
for f in dropbear_ed25519_host_key dropbear_rsa_host_key; do
    cmp -s "$F/etc/dropbear/$f" "$FIX/fake-full/$f" || fail "etc/dropbear/$f differs from the profile"
done
# R61: the SSH_KEYS of the fake profile first, then the line of the profile folder's file
cmp -s "$F/etc/dropbear/authorized_keys" "$FIX/fake-full-authorized_keys" ||
    fail "etc/dropbear/authorized_keys is not SSH_KEYS plus the profile's file"
[ "$(stat -c %a "$D/$UD")" = 700 ] || fail "$UD is not 0700"
[ "$(stat -c %a "$D/etc/crontabs/root")" = 600 ] || fail "crontab is not 0600"
[ "$(stat -c %a "$D/etc/init.d/lw-firstboot")" = 755 ] || fail "lw-firstboot is not executable"
[ "$(stat -c %a "$D/usr/lib/lw/lw-apn")" = 755 ] || fail "lw-apn is not executable"
[ "$(stat -c %a "$D/usr/lib/lw/common.sh")" = 644 ] || fail "common.sh is not 0644"
for f in usr/sbin/lw-heartbeat etc/hotplug.d/ntp/30-lw-nlbwmon; do
    [ "$(stat -c %a "$D/$f")" = 755 ] || fail "$f is not executable"
done
# Directory modes become those of /, /etc, /usr/sbin ... in the image (cp -p in ImageBuilder)
bad=$(find "$D" "$F" -type d ! -perm 755 ! -path "$F/etc/dropbear" ! -path "$F/etc/tailscale")
[ -z "$bad" ] || fail "overlay dirs not 0755: $bad"
[ "$(stat -c %a "$F/etc/dropbear")" = 700 ] || fail "etc/dropbear is not 0700"

# R63: an image without Tailscale is the files of src/files and its /etc/lw-build, nothing more: no
# tailscale file, directory, zone or uci section (the uci part is tests/firstboot/generic.sh)
diff <(cd "$FW/src/files" && find . | LC_ALL=C sort) <(cd "$D" && find . ! -path ./etc/lw-build | LC_ALL=C sort) >/dev/null ||
    fail "R63: the generic overlay is not src/files: $(diff <(cd "$FW/src/files" && find . | LC_ALL=C sort) <(cd "$D" && find . ! -path ./etc/lw-build | LC_ALL=C sort) | tr '\n' ' ')"
[ -z "$(find "$D" -ipath '*tailscale*')" ] || fail "R63: the generic overlay has a tailscale path"
[ -z "$(find "$RENDER/debug-plain" -ipath '*tailscale*')" ] || fail "R63: debug-plain has a tailscale path"
grep -qx "P_TS_ENABLED='0'" "$D/$UD" || fail "the generic overlay does not turn Tailscale off"

# R63, R64b: a tailscale overlay is src/files plus src/files-tailscale; the auth key is in one file
# only, 0600, in a 0700 directory, and without a key there is neither file nor directory
grep -qx "P_TS_ENABLED='1'" "$F/$UD" || fail "the fake-full overlay does not turn Tailscale on"
for rel in $(cd "$FW/src/files-tailscale" && find . -type f); do
    for n in fake-full ts-plain ts-key ts-lan; do
        cmp -s "$FW/src/files-tailscale/$rel" "$RENDER/$n/$rel" || fail "R63: $n lacks $rel of src/files-tailscale"
    done
done
[ "$(find "$F/etc/tailscale" -type f)" = "$F/etc/tailscale/lw-authkey" ] || fail "R64b: etc/tailscale holds other files than the key"
[ "$(printf '%s\n' "$FAKE_TS_AUTHKEY" | cmp - "$F/etc/tailscale/lw-authkey" && echo same)" = same ] ||
    fail "R64b: lw-authkey is not the profile's key and a newline"
[ "$(stat -c %a "$F/etc/tailscale/lw-authkey")" = 600 ] || fail "R64b: lw-authkey is not 0600"
[ "$(stat -c %a "$F/etc/tailscale")" = 700 ] || fail "R64b: etc/tailscale is not 0700"
[ "$(grep -rlaF "$FAKE_TS_AUTHKEY" "$F")" = "$F/etc/tailscale/lw-authkey" ] ||
    fail "R64b: the auth key is in other files than lw-authkey: $(grep -rlaF "$FAKE_TS_AUTHKEY" "$F" | tr '\n' ' ')"
grep -qx "P_TS_LAN_PREFIX='192.168.77.0/24'" "$F/$UD" || fail "R67: the LAN prefix of 192.168.77.1 is not 192.168.77.0/24"
grep -qx "P_TS_LAN_PREFIX='192.168.5.0/24'" "$RENDER/ts-lan/$UD" || fail "R67: the LAN prefix of 192.168.5.1 is not 192.168.5.0/24"
for n in ts-plain ts-lan; do
    [ ! -e "$RENDER/$n/etc/tailscale" ] || fail "R64b: $n has etc/tailscale without a key"
done
[ "$(stat -c %a "$RENDER/ts-key/etc/tailscale/lw-authkey")" = 600 ] || fail "R64b: ts-key lw-authkey is not 0600"
# the settings of the package file (R63h, D156): output out of syslog, the rest as the package has it
for line in "option log_stderr '0'" "option log_stdout '0'" "option port '41641'" \
    "option state_file '/etc/tailscale/tailscaled.state'"; do
    grep -qF "$line" "$F/etc/config/tailscale" || fail "R63h: etc/config/tailscale lacks '$line'"
done
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
# R3b, R7b: the version of the repository's VERSION file is in /etc/lw-build, one line, of both profiles
[ -f "$FW/VERSION" ] || fail "no VERSION file at the repository root"
version=$(cat "$FW/VERSION")
grep -qE '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$' "$FW/VERSION" ||
    fail "VERSION is not MAJOR.MINOR.PATCH"
[ "$(grep -c '^version=' "$D/etc/lw-build")" = 1 ] || fail "lw-build lacks one version line"
grep -qx "version=$version" "$D/etc/lw-build" || fail "lw-build version is not $version"
grep -qx "version=$version" "$F/etc/lw-build" || fail "fake-full version differs from generic"
# the lines an outside reader greps keep their format
grep -qE '^src_sha256=[0-9a-f]{64}$' "$D/etc/lw-build" || fail "src_sha256 line changed its format"
[ "$(wc -l <"$D/etc/lw-build")" = 4 ] || fail "lw-build is not four lines"
# the build prints the version in its summary line
printf '1.2.3-rc.1\n' >"$SCRATCH/VERSION"
LW_VERSION_FILE=$SCRATCH/VERSION "$FW/build.sh" --render-only generic "$SCRATCH/ver-out" 2>"$SCRATCH/ver-err"
grep -qE '^render: profile generic, version 1\.2\.3-rc\.1, src_sha256 [0-9a-f]{12}$' "$SCRATCH/ver-err" ||
    fail "render summary lacks the version: $(cat "$SCRATCH/ver-err")"

# R61 scenario: SSH_KEYS with two keys (A, B), the folder's authorized_keys with one of them (B, under
# another comment) and a third (C, behind an options prefix): three keys once each, SSH_KEYS first;
# the folder file's own lines stay as they are, and the comment does not make a key another key
sed "s|^SSH_KEYS=.*|SSH_KEYS='$FAKE_SSH_A;$FAKE_SSH_B'|" "$P/fake-full.conf" >"$P/ssh-merge.conf"
mkdir -p "$P/ssh-merge"
C_LINE="from=\"10.1.1.1\" $FAKE_SSH_C"
printf '%s other-comment\n%s\n' "$(ssh_field "$FAKE_SSH_B" 1) $(ssh_field "$FAKE_SSH_B" 2)" "$C_LINE" \
    >"$P/ssh-merge/authorized_keys"
LW_PROFILES=$P "$FW/build.sh" --render-only ssh-merge "$SCRATCH/ssh-merge" 2>/dev/null
AK=$SCRATCH/ssh-merge/etc/dropbear/authorized_keys
[ "$(cat "$AK")" = "$FAKE_SSH_A"$'\n'"$FAKE_SSH_B"$'\n'"$C_LINE" ] ||
    fail "R61: merged authorized_keys is not A, B, C once each in that order: $(cut -c1-60 "$AK")"
[ "$(stat -c %a "$AK" "$SCRATCH/ssh-merge/etc/dropbear")" = $'600\n700' ] ||
    fail "R61: merged authorized_keys is not 0600 in a 0700 directory"
# R61: the same key twice in SSH_KEYS (comment ignored), and every type, give each key once
sed "s|^SSH_KEYS=.*|SSH_KEYS=' $FAKE_SSH_R ; $FAKE_SSH_E ; $(ssh_field "$FAKE_SSH_R" 1) $(ssh_field "$FAKE_SSH_R" 2) again'|" \
    "$P/fake-full.conf" >"$P/ssh-types.conf"
LW_PROFILES=$P "$FW/build.sh" --render-only ssh-types "$SCRATCH/ssh-types" 2>/dev/null
[ "$(head -n 2 "$SCRATCH/ssh-types/etc/dropbear/authorized_keys")" = "$FAKE_SSH_R"$'\n'"$FAKE_SSH_E" ] ||
    fail "R61: ssh-rsa and ecdsa keys, trimmed around the ';', are not written as given"
[ "$(wc -l <"$SCRATCH/ssh-types/etc/dropbear/authorized_keys")" = 2 ] ||
    fail "R61: a key repeated in SSH_KEYS under another comment was written twice"
# R61: SSH_KEYS alone, without a folder file, makes the file; both empty make none (generic above)
sed "s|^SSH_KEYS=.*|SSH_KEYS='$FAKE_SSH_B'|" "$P/generic.conf" >"$P/ssh-only.conf"
LW_PROFILES=$P "$FW/build.sh" --render-only ssh-only "$SCRATCH/ssh-only" 2>/dev/null
[ "$(cat "$SCRATCH/ssh-only/etc/dropbear/authorized_keys")" = "$FAKE_SSH_B" ] ||
    fail "R61: SSH_KEYS alone did not give the image its key"
[ "$(ls "$SCRATCH/ssh-only/etc/dropbear")" = authorized_keys ] || fail "R61: SSH_KEYS alone made other files"
# R61: with SSH_KEYS empty the folder's file is copied as it is, comments, blank lines and repeats included
sed "s|^SSH_KEYS=.*|SSH_KEYS=''|" "$P/fake-full.conf" >"$P/ssh-none.conf"
mkdir -p "$P/ssh-none"
printf '# mine\n\n%s\n%s\n' "$FAKE_SSH_B" "$FAKE_SSH_B" >"$P/ssh-none/authorized_keys"
LW_PROFILES=$P "$FW/build.sh" --render-only ssh-none "$SCRATCH/ssh-none" 2>/dev/null
cmp -s "$SCRATCH/ssh-none/etc/dropbear/authorized_keys" "$P/ssh-none/authorized_keys" ||
    fail "R61: an empty SSH_KEYS changed the folder's authorized_keys"

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
for hint in 'https://192.168.1.1' certificate 'A reset with the button' WWAN_PIN APN 'LTE again at every boot' '2G (EDGE)' \
    'Scheduled Tasks' /root/sms-archive/ 'Country Code' 'ssh-keygen -R 192.168.1.1'; do
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
