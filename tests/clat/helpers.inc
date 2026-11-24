# Helpers for tests/clat/*.sh, sourced after /fw/tests/lib.sh. Not a test itself (no .sh suffix).
# shellcheck shell=sh disable=SC2034  # the constants are used by the tests that source this file
#
# The stand-ins of this area (tests/clat/stubs) are netifd with the stock protocol 464xlat (ubus),
# the operator's DNS64 (nslookup), the rules of ip and the test clock (sleep, which moves it).
# lw-clat-check is the image's script, run as the hotplug dispatch and wwan-recover run it.

C=$LW_TEST/clat
LOG=$LW_TEST/syslog
CL_DIR=/tmp/lw-clat
CL_PID=/tmp/clat/464-wwan_6_4.pid
CL_ANY=/tmp/clat/464-wwan_6_4-anycast
CL_NAT=/tmp/clat/nat46
CL_RULE0='from all lookup local pref 0'
DNS_ADDR=2001:db8:53::1
DNS_ADDR2=2001:db8:53::2
# the two answers of a DNS64 for ipv4only.arpa (192.0.0.170 and 192.0.0.171), well-known prefix
WKP_ANSWER='64:ff9b::c000:aa 64:ff9b::c000:ab'

# cl_setup: lw_setup, the stand-ins first on PATH, the state files of the helper in /tmp/clat, the
# one rule of the local table, a DNS64 answer, netifd with an IPv6-only session whose settings came
# through the DHCPv6 child wwan_6 (R76, R73j)
cl_setup() {
    lw_setup
    case $PATH in /fw/tests/clat/stubs:*) ;; *) PATH=/fw/tests/clat/stubs:$PATH ;; esac
    export PATH
    LW_CLAT_DIR=$CL_DIR LW_CLAT_PIDFILE=$CL_PID LW_CLAT_ANYCAST=$CL_ANY LW_CLAT_NAT46=$CL_NAT
    LW_CLAT_UPWAIT=3
    export LW_CLAT_DIR LW_CLAT_PIDFILE LW_CLAT_ANYCAST LW_CLAT_NAT46 LW_CLAT_UPWAIT
    # the helpers of an earlier setup of this test end with it
    for f in /proc/[0-9]*/cmdline; do
        p=${f#/proc/}
        case $({ tr '\0' ' ' <"$f"; } 2>/dev/null) in
            '464xlatcfg '*) kill "${p%/cmdline}" 2>/dev/null || : ;;
        esac
    done
    rm -r -f "$C" /tmp/clat "$CL_DIR" "$T/sleeps" "$T/syslog.prio" "$T/on-sleep"
    rm -f "$T"/ifstatus/*.unreadable
    mkdir -p "$C" /tmp/clat
    echo "$CL_RULE0" >"$C/rules"
    : >"$T/sleeps"
    : >"$LOG"
    lw_route_off
    lw_session v6child
    cl_session_mark s1
    cl_dns "$DNS_ADDR" "$WKP_ANSWER"
}

# cl_session_mark TOKEN: what the image's qmi.sh writes when an IPv6-only session sets up (the
# handles of the fixture of lw_session and a token of that setup); a new token is a new session even
# when the handles repeat
cl_session_mark() {
    mkdir -p "$CL_DIR"
    echo "18/3203210530/$1" >"$CL_DIR/v6only"
}

# cl_dns SERVER WHAT: the answer of one DNS server (tests/clat/stubs/nslookup); cl_dns_off clears them
cl_dns() { echo "$1 $2" >>"$C/dns"; }
cl_dns_off() { : >"$C/dns"; }

# cl_outcome up|fail|pending: what the setup of the stock protocol does (tests/clat/stubs/ubus)
cl_outcome() { echo "$1" >"$C/outcome"; }

# cl_tick / cl_new / cl_down: the check as wwan-recover, the hotplug of wwan_6 and the hotplug of
# the end of the session run it; the exit status
# of the check in CL_RC
cl_tick() { CL_RC=0; lw-clat-check tick || CL_RC=$?; }
cl_new() { CL_RC=0; lw-clat-check new || CL_RC=$?; }
cl_down() { CL_RC=0; lw-clat-check down || CL_RC=$?; }

# cl_live: the number of live processes of the helper 464xlatcfg
cl_live() {
    n=0
    for f in /proc/[0-9]*/cmdline; do
        case $({ tr '\0' ' ' <"$f"; } 2>/dev/null) in '464xlatcfg '*) n=$((n + 1)) ;; esac
    done
    echo "$n"
}

# cl_fake_helper ARG1 ...: a live process whose argv is $CL_ARGV0 (default 464xlatcfg) ARG1 ... (argv[0]
# and argv[1] are what ownership is decided on); its pid in FAKE. A ucode script named after ARG1 sleeps: busybox would
# not run under another argv[0]
cl_fake_helper() {
    mkdir -p "$C/fake"
    echo 'sleep(1000000);' >"$C/fake/$1"
    # shellcheck disable=SC2016  # the $0 and $@ belong to the inner shell
    (cd "$C/fake" && setsid sh -c 'exec -a "$0" /usr/bin/ucode "$@"' "${CL_ARGV0:-464xlatcfg}" "$@" </dev/null >/dev/null 2>&1 &
        echo $! >"$C/fake/pid")
    FAKE=$(cat "$C/fake/pid")
    _i=0
    while ! grep -qa 464xlatcfg "/proc/$FAKE/cmdline" 2>/dev/null && [ "$_i" -lt 20 ]; do
        _i=$((_i + 1))
        /bin/sleep 1
    done
}

# cl_nat46: the nat46 devices that exist (the last word of the file about a device decides)
cl_nat46() {
    awk '$1 == "add" { d[$2] = 1 } $1 == "del" { delete d[$2] } END { for (x in d) print x }' "$CL_NAT" 2>/dev/null
}

# cl_rules: the rules of the stand-in ip, one line each
cl_rules() { cat "$C/rules"; }

# cl_adds: the number of interfaces the stand-in netifd was asked to add
cl_adds() {
    [ -f "$C/ubus-calls" ] || { echo 0; return 0; }
    grep -c 'add_dynamic' "$C/ubus-calls" || :
}

# cl_clean_state: R76c: nothing of a translation is left: no helper, no pid file, no nat46 device, no
# marker, no rule but the one of the local table, no interface in netifd
cl_clean_state() {
    # a helper that was sent TERM is gone a moment later
    _i=0
    while [ "$(cl_live)" != 0 ] && [ "$_i" -lt 5 ]; do
        _i=$((_i + 1))
        /bin/sleep 1
    done
    lw_expect_eq "$(cl_live)" 0 "$1: live helpers"
    [ ! -e "$CL_PID" ] || lw_fail "$1: the pid file of the helper is left"
    lw_expect_eq "$(cl_nat46)" "" "$1: nat46 devices"
    [ ! -e "$CL_ANY" ] || lw_fail "$1: the address marker is left"
    lw_expect_eq "$(cl_rules)" "$CL_RULE0" "$1: rules"
    [ ! -e "$T/ifstatus/wwan_6_4.json" ] || lw_fail "$1: netifd still has wwan_6_4"
    [ ! -e "$CL_DIR/active" ] || lw_fail "$1: the mark of a translation is left"
}

# cl_removes: the number of times netifd was asked to remove wwan_6_4
cl_removes() {
    [ -f "$C/ubus-calls" ] || { echo 0; return 0; }
    grep -c 'network.interface.wwan_6_4 remove' "$C/ubus-calls" || :
}

# cl_translated LABEL: the translation made by cl_tick is still all there (nothing was taken away)
cl_translated() {
    lw_expect_eq "$(cl_live)" 1 "$1: live helpers"
    lw_expect_eq "$(cl_nat46)" 464-wwan_6_4 "$1: nat46 devices"
    [ -e "$CL_ANY" ] || lw_fail "$1: the address marker is gone"
    [ -e "$T/ifstatus/wwan_6_4.json" ] || lw_fail "$1: netifd lost wwan_6_4"
    lw_expect_eq "$(cl_removes)" 0 "$1: netifd was asked to remove wwan_6_4"
}

# cl_clat_lines: the syslog lines of the script
cl_clat_lines() { grep -c ' lw-clat: ' "$LOG" || :; }

# cl_quiet LABEL [PATTERN]: nothing of the translation happened: no DNS64 question, no interface, no
# helper, no line (but lines that match PATTERN: the debug note of a status that is not clear), no
# ifup or ifdown, no call of netifd
cl_quiet() {
    lw_expect_eq "$(cat "$C/dns-queries" 2>/dev/null)" "" "$1: DNS64 queries"
    lw_expect_eq "$(cat "$C/added" 2>/dev/null)" "" "$1: interfaces added"
    lw_expect_eq "$(cat "$C/ubus-calls" 2>/dev/null)" "" "$1: calls of ubus"
    lw_expect_eq "$(cl_live)" 0 "$1: live helpers"
    lw_expect_eq "$(grep -v -e "^1000 lw-clat: ${2:-@none@}\$" "$LOG" || :)" "" "$1: syslog"
    lw_expect_eq "$(cat "$T/events")" "" "$1: ifup or ifdown calls"
}
