# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc

case ${1:-all} in
all | restores)
    lk_setup
    mkdir -p "$T/bin" /tmp/elsewhere
    ln -s /tmp/elsewhere /var/run/lw-linkwatch
    : >/tmp/elsewhere/restores
    cat >"$T/bin/cat" <<'STUB'
#!/bin/sh
if [ "$1" = /var/run/lw-linkwatch/restores ]; then
    : >"$LW_TEST/read-unsafe-restores"
fi
exec /bin/busybox cat "$@"
STUB
    chmod +x "$T/bin/cat"
    lk_lost
    PATH="$T/bin:$PATH" lw-linkwatch once
    [ ! -e "$T/read-unsafe-restores" ] || lw_fail "read restores through a directory symlink"
    ;;
esac

case ${1:-all} in
all | birth)
    lk_setup
    lw_uptime_set 1000
    LK_IFBIRTH=900
    lk_netifd up
    lk_lost
    mkdir -p /var/run/lw-linkwatch
    printf '17/3203210528 900+0\n' >/var/run/lw-linkwatch/escalated
    lw-linkwatch once || lw_fail "invalid escalation birth broke the poll"
    lw_expect_eq "$(lk_calls_of --start-network)" 1 "restore after a malformed escalation"
    ;;
esac
echo ok
