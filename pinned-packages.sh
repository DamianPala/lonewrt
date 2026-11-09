# shellcheck shell=bash
# Sourced by build.sh and tests/vm/build-image.sh (SPEC R2a, D77): copies the third-party .apk files
# into an ImageBuilder only as deps.lst pins them. The caller sets LW_WORK and DEPS and has a die().

# Package name and version of an .apk file name (apk version syntax: 1.0.31-r1, 20260806-r1,
# 1718~981c978eff); the name may itself hold digits and dashes (modemband-5g, libpcre2-16)
APK_NAME='^(.+)-([0-9][0-9.]*[a-z]?(_[a-z]+[0-9]*)*(~[0-9a-f]+)?(-r[0-9]+)?)\.apk$'

# apk_name FILE: the package name of an .apk file name; empty when it does not read as name-version
apk_name() {
    if [[ ${1##*/} =~ $APK_NAME ]]; then echo "${BASH_REMATCH[1]}"; fi
}

# install_extra_packages PACKAGES_DIR STAGE_DIR: each file of the group `extra` of deps.lst must be
# in $LW_WORK with its listed sha256 (taken of a copy in STAGE_DIR, and that copy is what goes into
# the ImageBuilder, so the file cannot change in between), a package is pinned once, and dl/extra
# holds no other .apk. Then files of other versions of the same packages leave PACKAGES_DIR (a
# package is another one when its name differs, even by a suffix; the ImageBuilder's own files
# stay) and the pinned files are copied. Nothing in PACKAGES_DIR changes before every check passed.
install_extra_packages() {
    local pkgs=$1 stage=$2 group sum path _ file base name old
    local -A pinned=()
    local listed=()
    mkdir -p "$stage"
    while read -r group sum path _; do
        [ "$group" = extra ] || continue
        file=$LW_WORK/$path
        base=${file##*/}
        name=$(apk_name "$base")
        [ -n "$name" ] || die "$base in deps.lst does not read as name-version.apk, cannot pin it"
        if [ -n "${pinned[$name]:-}" ]; then
            die "deps.lst pins $name twice: ${pinned[$name]} and $base"
        fi
        pinned[$name]=$base
        [ -f "$file" ] || die "pinned package $file is missing: run ./fetch-deps.sh extra"
        cp -- "$file" "$stage/"
        if [ "$(sha256sum "$stage/$base" | cut -d' ' -f1)" != "$sum" ]; then
            die "$file does not match its sha256 in deps.lst:" \
                "delete it and run ./fetch-deps.sh extra"
        fi
        listed+=("$file")
    done < <(grep -v '^[[:space:]]*#' "$DEPS")
    [ "${#listed[@]}" -gt 0 ] || die "no group extra in $DEPS"
    for file in "$LW_WORK"/dl/extra/*.apk; do
        [ -e "$file" ] || continue
        printf '%s\n' "${listed[@]}" | grep -qxF -- "$file" ||
            die "$file is not listed in deps.lst: remove it from dl/extra"
    done
    for old in "$pkgs"/*.apk; do
        [ -e "$old" ] || continue
        name=$(apk_name "$old")
        if [ -n "$name" ] && [ -n "${pinned[$name]:-}" ] && [ "${old##*/}" != "${pinned[$name]}" ]; then
            rm -f -- "$old"
        fi
    done
    for file in "${listed[@]}"; do
        cp -- "$stage/${file##*/}" "$pkgs/"
    done
}
