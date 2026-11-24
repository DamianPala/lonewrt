#!/usr/bin/env bash
# Real ImageBuilder builds (about 1,5 min each; the uqmi package for qmi.sh comes from the network,
# R12d): the generic image twice into a scratch image/ (R33: the second build keeps the card and its
# passwords; the real image/ is not touched),
# its rootfs free of private and fake-profile values (R4, R4a) and its manifest against packages.md (R2);
# then the fake full profile into another scratch image/ whose rootfs carries the profile's values
# and SSH keys (R7, R31), the heartbeat line (R42) and the nlbwmon hotplug script (R44a). In both
# images qmi.sh is the uqmi package's file of that build with the edits of qmi-handler.sh (R12d to R12f, D82).
# The generic image has no Tailscale, the fake one is a tailscale image (R63 to R64b): the packages
# in its manifest, the version in /etc/lw-build, the key file and the size of the root.
# shellcheck source=tests/build/lib.bash
source "$(dirname "$0")/lib.bash"
scratch images
UD=etc/uci-defaults/zz-lw-config
die() { fail "$*"; }
# shellcheck source=qmi-handler.sh
source "$FW/qmi-handler.sh"
# shellcheck source=watchcat-handler.sh
source "$FW/watchcat-handler.sh"
LW_ROOTFS=${LW_ROOTFS:-$LW_WORK/dl/x86/rootfs}

# The note that marks an "Included" row as a tailscale image's only (SPEC R2, R63)
TS_NOTE="only with \`TS_ENABLED='1'\`"

# rows_in TABLE: the package rows of a packages.md table
rows_in() {
    # shellcheck disable=SC2016  # literal backticks of the markdown table
    awk -v want="$1" '/^## /{on = index($0, want) > 0; next} on && /^\| `/' "$FW/packages.md"
}

# names_of: the backticked package names in the first column of the rows on stdin (names inside
# parentheses are dependencies pulled in, not packages to ask for)
names_of() {
    # shellcheck disable=SC2016  # literal backticks of the markdown table
    cut -d'|' -f2 | sed 's/([^)]*)//g' | grep -o '`[^`]*`' | tr -d '`'
}

packages_in() { rows_in "$1" | names_of; }

# ts_packages_in: the "Included" rows marked as a tailscale image's only
ts_packages_in() { rows_in Included | grep -F "$TS_NOTE" | names_of; }

# check_manifest FILE [ts]: every "Included" package installed, none of "Left out" (SPEC R2); the rows
# marked "only with TS_ENABLED='1'" only in a tailscale image (R63), which is the argument ts
check_manifest() {
    local installed pkg ts_only
    installed=$(cut -d' ' -f1 "$1")
    ts_only=$(ts_packages_in)
    while read -r pkg; do
        if [ "${2:-}" != ts ] && grep -qxF -- "$pkg" <<<"$ts_only"; then
            ! grep -qx -- "$pkg" <<<"$installed" || fail "R63: the manifest of an image without Tailscale has $pkg"
        else
            grep -qx -- "$pkg" <<<"$installed" || fail "manifest lacks $pkg"
        fi
    done < <(packages_in Included)
    while read -r pkg; do
        while read -r name; do
            # shellcheck disable=SC2053  # the table uses globs such as collectd*
            if [[ $name == $pkg ]]; then fail "manifest has rejected $name"; fi
        done <<<"$installed"
    done < <(packages_in 'Left out')
    # D167: the packages the image removes from the default set are not installed (a dependency that
    # needs one of them would bring it back, and then the build fails or the manifest has it)
    while read -r pkg; do
        ! grep -qx -- "$pkg" <<<"$installed" || fail "D167: the manifest has the removed package $pkg"
    done < <(packages_in Removed)
}

# check_qmi ROOTFS: R12d to R12f, D82. The image's qmi.sh is the file of the uqmi package that went
# into this very build (root.orig-*, the pristine package rootfs the ImageBuilder copies from) with
# the edits of qmi-handler.sh (that file has the pinned sha256), differs from it in nothing else, runs
# under sh -n, keeps the package's mode, and has the negotiation of qmi-edits/ (no network-scan line,
# the injected functions in it). Call it right after the build: the next build replaces root.orig-*.
check_qmi() {
    local img=$1/$QMI_SH_REL orig want
    orig=$(compgen -G "$LW_WORK/ib/build_dir/target-*/root.orig-*" | head -n1) || true
    [ -f "$orig/$QMI_SH_REL" ] || fail "no pristine /$QMI_SH_REL under $LW_WORK/ib/build_dir (root.orig-*)"
    [ -f "$img" ] || fail "image lacks /$QMI_SH_REL"
    [ "$(sha256sum "$orig/$QMI_SH_REL" | cut -d' ' -f1)" = "$QMI_STOCK_SHA256" ] ||
        fail "the package's /$QMI_SH_REL is not the pinned file (R12e)"
    want=$SCRATCH/qmi-want.sh
    (qmi_transform "$orig/$QMI_SH_REL" "$want" "the package's file") || fail "the pristine /$QMI_SH_REL cannot be transformed"
    cmp -s "$want" "$img" || fail "image /$QMI_SH_REL is not the package file with the edits: $(diff "$want" "$img" | head -n 6)"
    ! grep -q -e "$QMI_SCAN_PATTERN" "$img" || fail "image /$QMI_SH_REL still has the network scan"
    grep -q '^lw_negotiate()' "$img" || fail "image /$QMI_SH_REL has no negotiation function"
    [ "$(stat -c %a "$img")" = "$(stat -c %a "$orig/$QMI_SH_REL")" ] || fail "/$QMI_SH_REL mode differs from the package's"
    qmi_sh_n "$img" || fail "image /$QMI_SH_REL fails sh -n"
}

# check_watchcat ROOTFS: R14b, R14c, D195. The image's /usr/bin/watchcat.sh and /etc/init.d/watchcat are
# the files of the watchcat package of this very build (root.orig-*) with the edits of
# watchcat-handler.sh (the pinned sha256 of both), differ in nothing else, run under sh -n, keep the
# package's modes, and the hook the worker loads is in the image. Call it right after the build.
check_watchcat() {
    local img=$1 orig f out
    orig=$(compgen -G "$LW_WORK/ib/build_dir/target-*/root.orig-*" | head -n1) || true
    for f in "$WC_SH_REL" "$WC_INIT_REL"; do
        [ -f "$orig/$f" ] || fail "no pristine /$f under $LW_WORK/ib/build_dir (root.orig-*)"
        [ -f "$img/$f" ] || fail "image lacks /$f"
        [ "$(stat -c %a "$img/$f")" = "$(stat -c %a "$orig/$f")" ] || fail "/$f mode differs from the package's"
        qmi_sh_n "$img/$f" || fail "image /$f fails sh -n"
    done
    [ "$(sha256sum "$orig/$WC_SH_REL" | cut -d' ' -f1)" = "$WC_STOCK_SHA256" ] || fail "the package's /$WC_SH_REL is not the pinned file (R14c)"
    [ "$(sha256sum "$orig/$WC_INIT_REL" | cut -d' ' -f1)" = "$WC_INIT_STOCK_SHA256" ] || fail "the package's /$WC_INIT_REL is not the pinned file (R14c)"
    out=$SCRATCH/wc-want
    mkdir -p "$out"
    (wc_transform "$orig/$WC_SH_REL" "$orig/$WC_INIT_REL" "$out/sh" "$out/init" "the package's files") ||
        fail "the pristine watchcat files cannot be transformed"
    cmp -s "$out/sh" "$img/$WC_SH_REL" || fail "image /$WC_SH_REL is not the package file with the edits"
    cmp -s "$out/init" "$img/$WC_INIT_REL" || fail "image /$WC_INIT_REL is not the package file with the edits"
    [ -f "$img/usr/lib/lw/watchcat-family.sh" ] || fail "image lacks the hook /usr/lib/lw/watchcat-family.sh"
    grep -qx "	option lw_family_check '1'" "$img/etc/config/watchcat" || fail "image's /etc/config/watchcat lacks the hook option"
}

# packages_of FILE: the names in the PACKAGES=( ... ) list of a build script, sorted
packages_of() {
    sed -n '/^PACKAGES=(/,/^)/p' "$1" | sed '1d;$d' | tr ' ' '\n' | sed '/^$/d' | sort
}

# Every row of the two tables starts with a package name in backticks: packages_in reads only such
# rows, so any other row would drop out of the checks of R2 without a word
# shellcheck disable=SC2016  # literal backticks of the markdown table
stray=$(awk '/^## /{on = /Included|Left out/; next}
    on && /^\|/ && !/^\| `/ && !/^\| Package / && !/^\|---/' "$FW/packages.md")
[ -z "$stray" ] || fail "packages.md: a table row does not start with a package name in backticks: ${stray:0:60}"

# D167: build.sh removes exactly the "Removed" table from the default set, and asks for the power-user tools
removed_want=$(packages_in Removed | sort)
[ -n "$removed_want" ] || fail "packages.md has no \"Removed from the default set\" rows"
removed_have=$(sed -n 's/^REMOVED_PACKAGES=(\(.*\))$/\1/p' "$FW/build.sh" | tr ' ' '\n' | sort)
[ "$removed_want" = "$removed_have" ] ||
    fail "build.sh REMOVED_PACKAGES differ from packages.md: $(diff <(echo "$removed_want") <(echo "$removed_have") | tr '\n' ' ')"
for pkg in ppp ppp-mod-pppoe kmod-ppp kmod-pppoe kmod-pppox; do
    grep -qxF "$pkg" <<<"$removed_have" || fail "D167: $pkg is not removed"
    ! packages_of "$FW/build.sh" | grep -qxF "$pkg" || fail "D167: PACKAGES of build.sh asks for the removed $pkg"
done
for pkg in tmux mtr-nojson vim; do
    packages_in Included | grep -qxF "$pkg" || fail "D167: packages.md does not include $pkg"
    packages_of "$FW/build.sh" | grep -qxF "$pkg" || fail "D167: build.sh does not install $pkg"
done

# build.sh installs exactly the "Included" table minus the default-set row and the rows marked as a
# tailscale image's only, which it adds as TS_PACKAGES for a tailscale profile (R63)
DEFAULT_SET='uqmi|kmod-.*|wpad-basic-mbedtls|firewall4|dnsmasq|dropbear'
packages_in Included | grep -qxE "$DEFAULT_SET" || fail "packages.md \"Included\" has no row of the default set"
ts_want=$(ts_packages_in | sort)
[ -n "$ts_want" ] || fail "packages.md \"Included\" has no row marked $TS_NOTE"
want=$(packages_in Included | grep -vxE "$DEFAULT_SET" | grep -vxFf <(echo "$ts_want") | sort)
have=$(packages_of "$FW/build.sh")
[ "$want" = "$have" ] || fail "build.sh PACKAGES differ from packages.md: $(diff <(echo "$want") <(echo "$have") | tr '\n' ' ')"
ts_have=$(sed -n 's/^TS_PACKAGES=(\(.*\))$/\1/p' "$FW/build.sh" | tr ' ' '\n' | sort)
[ "$ts_want" = "$ts_have" ] || fail "build.sh TS_PACKAGES differ from packages.md: $(diff <(echo "$ts_want") <(echo "$ts_have") | tr '\n' ' ')"

# The VM bench installs the same list without the packages no VM test uses, plus the device
# defaults that the x86 profile does not bring (tests/vm/README.md)
vm_want=$({
    grep -vxE 'speedtestcpp|qrencode|libjpeg-turbo-utils|tmux|mtr-nojson|vim' <<<"$have"
    printf '%s\n' uqmi kmod-usb-net-qmi-wwan kmod-usb-serial-option wpad-basic-mbedtls
} | sort)
vm_have=$(packages_of "$FW/tests/vm/build-image.sh")
[ "$vm_want" = "$vm_have" ] ||
    fail "tests/vm/build-image.sh PACKAGES differ from build.sh: $(diff <(echo "$vm_want") <(echo "$vm_have") | tr '\n' ' ')"

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
check_qmi "$R"
check_watchcat "$R"
assert_absent "$R" "${LW_VALUES[@]}" "${FAKE_VALUES[@]}"
# R63: no Tailscale in an image without it: no package file, config or state directory, and no line in /etc/lw-build
for f in usr/sbin/tailscaled usr/sbin/tailscale etc/config/tailscale etc/tailscale; do
    [ ! -e "$R/$f" ] || fail "R63: the generic image has /$f"
done
! grep -q '^tailscale=' "$R/etc/lw-build" || fail "R63b: the generic image has a tailscale= line"
[ -z "$(ls -A "$R/etc/dropbear")" ] || fail "generic image has files in /etc/dropbear"
[ "$(stat -c %a "$R" "$R/etc" "$R/usr/sbin" | sort -u)" = 755 ] || fail "/, /etc or /usr/sbin not 0755"
for f in "$UD" etc/init.d/lw-firstboot etc/lw-build etc/config/lonewrt etc/config/watchcat \
    etc/crontabs/root usr/lib/lw/common.sh etc/init.d/lw-notify usr/sbin/lw-notify \
    usr/sbin/lw-heartbeat etc/init.d/lw-linkwatch usr/sbin/lw-linkwatch etc/hotplug.d/ntp/30-lw-nlbwmon usr/lib/lw/devices.sh usr/lib/lw/reboot.sh usr/lib/lw/names.sh; do
    [ -e "$R/$f" ] || fail "generic image lacks /$f"
done
# ImageBuilder enables every rc.common script of FILES in the image itself, so the services start
# on the very first boot (procd globs /etc/rc.d before S10boot runs uci-defaults) and after a reset
for s in lw-modem-mode lw-firstboot lw-linkwatch watchcat cron nlbwmon; do
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
LW_PROFILES=$P LW_IMAGE=$I "$FW/build.sh" fake-full >/dev/null 2>"$SCRATCH/fake-full.err"
! grep -q 'warning: the tailscale package' "$SCRATCH/fake-full.err" ||
    fail "R63g: the build warned about the tailscale package: $(grep 'warning: the tailscale' "$SCRATCH/fake-full.err")"
[ ! -e "$I/fake-full-passwords.txt" ] || fail "a profile with both passwords got a card"
# ImageBuilder's build_dir keeps no copy of the profile's rootfs or image (SPEC D15)
assert_absent "$LW_WORK/ib" "${FAKE_VALUES[@]}"
check_manifest "$I/fake-full.manifest" ts
mkdir -p "$SCRATCH/fake"
unpack_image "$I/fake-full-sysupgrade.bin" "$SCRATCH/fake"
R=$SCRATCH/fake/rootfs
check_qmi "$R"
check_watchcat "$R"
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
# R61: the image's authorized_keys is the profile's SSH_KEYS and then the folder's file
cmp -s "$R/etc/dropbear/authorized_keys" "$FIX/fake-full-authorized_keys" ||
    fail "R61: image authorized_keys is not SSH_KEYS plus the profile's file"
[ "$(stat -c %a "$I/fake-full-sysupgrade.bin")" = 600 ] || fail "image file is not 0600"
# R63, R63a, R63b, R64b: the fake profile is a tailscale image: the package's files, the version of
# the manifest in /etc/lw-build, the profile's settings over the package's, the auth key in one
# file of mode 0600, and a root file system within the limit
for f in usr/sbin/tailscaled usr/sbin/tailscale etc/init.d/tailscale; do
    [ -e "$R/$f" ] || fail "R63: the tailscale image lacks /$f"
done
ts_version=$(awk '$1 == "tailscale" {print $3}' "$I/fake-full.manifest")
[ -n "$ts_version" ] || fail "R63: the manifest has no tailscale version"
[ "$(tail -n 1 "$R/etc/lw-build")" = "tailscale=$ts_version" ] ||
    fail "R63b: /etc/lw-build does not end with tailscale=$ts_version: $(tail -n 1 "$R/etc/lw-build")"
grep -qF "option log_stdout '0'" "$R/etc/config/tailscale" || fail "R63h: the image has the package's etc/config/tailscale, not ours"
[ "$(stat -c %a "$R/etc/tailscale/lw-authkey")" = 600 ] || fail "R64b: /etc/tailscale/lw-authkey is not 0600 in the image"
[ "$(grep -rlaF "$FAKE_TS_AUTHKEY" "$R")" = "$R/etc/tailscale/lw-authkey" ] ||
    fail "R64b: the auth key is in other files than lw-authkey"
root_bytes=$(tar -tvf "$I/fake-full-sysupgrade.bin" --wildcards '*/root' | awk '{print $3}')
[ "$root_bytes" -le 15500000 ] || fail "R63a: the root of the tailscale image is $root_bytes bytes"
echo "tailscale image: tailscale $ts_version, root $root_bytes bytes" >&2
echo "ok: $(stat -c %s "$DI/generic-sysupgrade.bin") bytes (scratch image, removed with the test)"
