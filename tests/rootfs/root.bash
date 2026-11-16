# Sourced by the scripts that start the OpenWrt rootfs under bwrap (tests/rootfs/run.sh,
# tests/hostnet/*.sh). root_args ROOTFS DIR sets ROOT_ARGS to the bwrap arguments of a throwaway
# writable / made from ROOTFS. bwrap from 0.10 has --overlay-src; older ones (0.9.0 on the GitHub
# runner's Ubuntu 24.04) get a copy of the rootfs in DIR, which the caller removes afterwards.
# shellcheck disable=SC2034  # ROOT_ARGS is read by the caller
root_args() {
    if bwrap --help 2>&1 | grep -q -- '--overlay-src'; then
        ROOT_ARGS=(--overlay-src "$1" --tmp-overlay /)
    else
        cp -a "$1" "$2/root"
        ROOT_ARGS=(--bind "$2/root" /)
    fi
}
