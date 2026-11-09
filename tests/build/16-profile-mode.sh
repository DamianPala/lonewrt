#!/usr/bin/env bash
# SPEC R3a: a profile file with a non-empty secret key, or a private SSH host key in the profile's
# folder, that group or others can read gets one warning that names the file(s) and suggests chmod
# 600; the build goes on, the warning never shows a value, and a profile without secrets, one that
# is 0600, or public key files (authorized_keys) get none.
# shellcheck source=tests/build/lib.bash
source "$(dirname "$0")/lib.bash"
scratch mode
P=$SCRATCH/profiles
make_profiles "$P"

# render NAME: stderr of a render-only build of the profile, which must succeed
render() {
    local out
    out=$(LW_PROFILES=$P "$FW/build.sh" --render-only "$1" "$(mktemp -d "$SCRATCH/out.XXXXXX")" 2>&1 1>/dev/null) ||
        fail "build.sh --render-only $1 failed: $out"
    echo "$out"
}
warnings() { grep -c 'warning' <<<"$1" || true; }

# a profile without any secret: the fake one with the secret keys emptied
SECRETS=(WIFI_KEY ROOT_PASSWORD ROOT_PASSWORD_HASH WWAN_PASSWORD WG_PRIVATE_KEY TG_BOT_TOKEN HC_PING_URL)
expr=()
for key in "${SECRETS[@]}"; do expr+=(-e "s/^$key=.*/$key=''/"); done
sed "${expr[@]}" -e "s/^WG_ENABLED=.*/WG_ENABLED='0'/" "$P/fake-full.conf" >"$P/open.conf"
chmod 664 "$P/open.conf" "$P/generic.conf"
err=$(render open)
[ "$(warnings "$err")" = 0 ] || fail "a profile without secrets got a warning: $err"
err=$(render generic)
[ "$(warnings "$err")" = 0 ] || fail "generic.conf got a warning: $err"

# each secret key alone, group or others can read: one warning with the file name and chmod 600
for key in "${SECRETS[@]}"; do
    value=$(grep "^$key=" "$P/fake-full.conf")
    [ "$key" != ROOT_PASSWORD ] || value="ROOT_PASSWORD='fake-root-pw-q7x9'"
    sed "s|^$key=.*|$value|" "$P/open.conf" >"$P/one.conf"
    chmod 664 "$P/one.conf"
    err=$(render one)
    [ "$(warnings "$err")" = 1 ] || fail "$key: expected one warning, got: $err"
    grep -qF "$P/one.conf" <<<"$err" || fail "$key: the warning does not name the file"
    grep -qF "chmod 600" <<<"$err" || fail "$key: the warning does not suggest chmod 600"
    plain=${value#*=}
    ! grep -qF -- "${plain//\'/}" <<<"$err" || fail "$key: the warning shows the value"
    chmod 600 "$P/one.conf"
    err=$(render one)
    [ "$(warnings "$err")" = 0 ] || fail "$key: a 0600 profile got a warning: $err"
done

# private key files in profiles/<name>/: the two host keys count, authorized_keys does not
mkdir -p "$P/open"
cp "$FIX"/fake-full/* "$P/open/"
chmod 664 "$P/open/"*
err=$(render open)
[ "$(warnings "$err")" = 1 ] || fail "loose host keys: expected one warning, got: $err"
for f in dropbear_ed25519_host_key dropbear_rsa_host_key; do
    grep -qF "$P/open/$f" <<<"$err" || fail "the warning does not name $f"
done
! grep -qF "$P/open/authorized_keys" <<<"$err" || fail "the warning names authorized_keys"
grep -qF "chmod 600" <<<"$err" || fail "the host key warning does not suggest chmod 600"
for v in "${FAKE_VALUES[@]}"; do
    ! grep -qF -- "$v" <<<"$err" || fail "the host key warning shows '$v'"
done
chmod 600 "$P/open/dropbear_ed25519_host_key"
err=$(render open)
[ "$(warnings "$err")" = 1 ] || fail "one loose host key: expected one warning, got: $err"
grep -qF "$P/open/dropbear_rsa_host_key" <<<"$err" || fail "the warning does not name the loose key"
! grep -qF "$P/open/dropbear_ed25519" <<<"$err" || fail "the warning names the key that is 0600"
chmod 600 "$P/open/dropbear_rsa_host_key"
err=$(render open)
[ "$(warnings "$err")" = 0 ] || fail "0600 host keys and a public authorized_keys got a warning: $err"
# a loose profile file and loose host keys together are still one warning
chmod 664 "$P/open/dropbear_rsa_host_key"
sed "s|^WIFI_KEY=.*|WIFI_KEY='fake-wifi-key-q7x9'|" "$P/open.conf" >"$P/open.conf.new"
mv "$P/open.conf.new" "$P/open.conf"
chmod 664 "$P/open.conf"
err=$(render open)
[ "$(warnings "$err")" = 1 ] || fail "profile and host key loose: expected one warning, got: $err"
grep -qF "$P/open.conf" <<<"$err" || fail "the combined warning does not name the profile: $err"
grep -qF "$P/open/dropbear_rsa_host_key" <<<"$err" || fail "the combined warning does not name the key: $err"

# the full fake profile: group-readable, other-readable only, 0600, 0700
chmod 600 "$P"/fake-full/*
for mode in 640 604 664 644; do
    chmod "$mode" "$P/fake-full.conf"
    err=$(render fake-full)
    [ "$(warnings "$err")" = 1 ] || fail "mode $mode: expected one warning, got: $err"
    for v in "${FAKE_VALUES[@]}"; do
        ! grep -qF -- "$v" <<<"$err" || fail "mode $mode: the warning shows '$v'"
    done
done
for mode in 600 700 400; do
    chmod "$mode" "$P/fake-full.conf"
    err=$(render fake-full)
    [ "$(warnings "$err")" = 0 ] || fail "mode $mode: got a warning: $err"
done

# a warning, not an error: a full build run stops later for other reasons, never for the mode
chmod 664 "$P/fake-full.conf"
LW_PROFILES=$P "$FW/build.sh" --render-only fake-full "$SCRATCH/final" 2>/dev/null ||
    fail "a readable profile stopped the build"
echo ok
