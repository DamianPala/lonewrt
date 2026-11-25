# R76, R76b, D186, D200: a translation exists only in a session that has no native IPv4. The IPv4
# router of the owner, a dual-stack session, a dual-stack session that lost its IPv4 and a session
# with no data at all get none: no interface, no 464xlat helper, no DNS64 query, no line in the
# log (at the info level and at the debug level); a translation left by an earlier session is taken
# out without a word. A session with IPv6 settings from the modem's report has no IPv6 child to hang
# the translation on, and gets none either. wwan-recover starts the check only for the sessions
# that can have one (the hotplug dispatch has its own test, r76b-hotplug-dispatch.sh).
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/clat/helpers.inc
. /fw/tests/clat/helpers.inc

for kind in v4 legacy dual none; do
    for level in info debug; do
        cl_setup
        case $kind in
            v4 | legacy | dual | v6) lw_session "$kind" ;;
            none) rm -f "$T"/ifstatus/*.json ;;
        esac
        LW_LOG_LEVEL=$level
        export LW_LOG_LEVEL
        cl_tick
        lw_expect_eq "$CL_RC" 0 "$kind $level: exit status of tick"
        cl_new
        lw_expect_eq "$CL_RC" 0 "$kind $level: exit status of new"
        # a status of wwan that is not clear (no data of the calls) is said at the debug level only
        case $kind$level in
            legacydebug | nonedebug) cl_quiet "$kind $level" 'what netifd says about wwan is not clear, nothing changed' ;;
            *) cl_quiet "$kind $level" ;;
        esac
        unset LW_LOG_LEVEL
    done
done

# an IPv6-only session with no child wwan_6 (settings from the modem's report, which an IPv6-only
# session of this image never has): nothing to hang the translation on; the debug level says why
cl_setup
lw_session v6
cl_tick
cl_quiet "IPv6 only, no child"
LW_LOG_LEVEL=debug
export LW_LOG_LEVEL
cl_tick
unset LW_LOG_LEVEL
lw_expect_eq "$(cl_adds)" 0 "IPv6 only, no child: interfaces added"
grep -q 'wwan_6 is not up yet' "$LOG" || lw_fail "IPv6 only, no child: no debug line"

# a dual-stack session that lost its IPv4 (wwan_4 gone, the data of wwan unchanged, the IPv6 child
# there) on a network with DNS64: no translation (D200)
cl_setup
lw_session dual
printf '{"up":true,"l3_device":"wwan0","ipv6-address":[{"address":"2001:db8:1::2","mask":64}],"dns-server":["%s"]}\n' \
    "$DNS_ADDR" >"$T/ifstatus/wwan_6.json"
rm -f "$T/ifstatus/wwan_4.json"
cl_tick
cl_new
cl_quiet "dual stack that lost its IPv4"

# an IPv4 call that is only half there counts as native IPv4, and a wwan that is down wants none
cl_setup
printf '{"up":true,"l3_device":"wwan0","data":{"cid_6":"18","pdh_6":"3203210530","cid_4":"17"}}\n' >"$T/ifstatus/wwan.json"
cl_tick
cl_quiet "half an IPv4 call"
cl_setup
printf '{"up":false,"data":{"cid_6":"18","pdh_6":"3203210530"}}\n' >"$T/ifstatus/wwan.json"
cl_tick
cl_quiet "wwan down"

# R76b: the translation of an earlier IPv6-only session is gone when the next session has native IPv4
# (the hotplug of the parent runs the check while a translation exists)
cl_setup
cl_tick
lw_expect_eq "$(cl_live)" 1 "setup: the first session has a helper"
lw_expect_eq "$(cl_clat_lines)" 1 "setup: the first session says it is up"
lw_session v4
cl_new
cl_clean_state "next session with native IPv4"
lw_expect_eq "$(cl_clat_lines)" 1 "next session: only the line of the first session ($(cat "$LOG"))"
# ... also when the next session is a dual-stack one with an IPv6 child
cl_setup
cl_tick
lw_session dual
printf '{"up":true,"l3_device":"wwan0","ipv6-address":[{"address":"2001:db8:1::2","mask":64}],"dns-server":["%s"]}\n' \
    "$DNS_ADDR" >"$T/ifstatus/wwan_6.json"
cl_tick
cl_clean_state "next session dual stack"

# R76b: a DNS64 answer for the previous session cannot make a translation in the new native IPv4 session
cl_setup
cp "$T/ifstatus/wwan.json" "$C/wwan-ipv6.json"
lw_session v4
cp "$T/ifstatus/wwan.json" "$C/wwan-during-dns.json"
mv "$C/wwan-ipv6.json" "$T/ifstatus/wwan.json"
cl_tick
lw_expect_eq "$(cl_adds)" 0 "IPv4 started during DNS64: no translation added"
lw_expect_eq "$(cl_clat_lines)" 0 "IPv4 started during DNS64: no log line"
cl_clean_state "IPv4 started during DNS64"

# wwan-recover: the ladder's run ends with the check in a session of IPv6 alone, and in no other
# shellcheck source=tests/ladder/ladder.inc
. /fw/tests/ladder/ladder.inc
printf '#!/bin/sh\necho "$*" >>"$LW_TEST/clat/check-calls"\n' >"$C/recorder"
chmod +x "$C/recorder"
LW_CLAT_CHECK=$C/recorder
export LW_CLAT_CHECK
for kind in v4 legacy dual v6 v6clat v6child; do
    : >"$C/check-calls"
    lw_session "$kind"
    lw_reach_none
    lw_reach 6 wwan0
    lw_reach 4 wwan0
    lw_reach 4 464-wwan_6_4
    runs 1
    case $kind in
        v6 | v6clat | v6child) want=tick ;;
        *) want='' ;;
    esac
    lw_expect_eq "$(cat "$C/check-calls")" "$want" "wwan-recover on a $kind session"
done
# R76c: the translation is up and the IPv4 probe of this very run got no answer through it: the check is
# told (`tick v4fail`), with no ping of its own; the IPv6 answer keeps the session online. A translation
# that is not up (no IPv4 probe was made) and one that answers get the plain tick
for kind in v6clat v6child; do
    : >"$C/check-calls"
    lw_session "$kind"
    lw_reach_none
    lw_reach 6 wwan0
    runs 1
    case $kind in
        v6clat) want='tick v4fail' ;;
        *) want=tick ;;
    esac
    lw_expect_eq "$(cat "$C/check-calls")" "$want" "wwan-recover on a $kind session, IPv4 does not answer"
done
# the mark of a cleanup that the hotplug could not do (R76c): the run calls the check for it in any
# session, and only then (the test is a builtin, an IPv4-only router starts nothing)
for kind in v4 dual ended; do
    : >"$C/check-calls"
    case $kind in
        ended) lw_session v4 && printf '{"up":false}\n' >"$T/ifstatus/wwan.json" ;;
        *) lw_session "$kind" ;;
    esac
    mkdir -p "$CL_DIR"
    : >"$CL_DIR/cleanup"
    lw_reach_none
    lw_reach 6 wwan0
    lw_reach 4 wwan0
    runs 1
    lw_expect_eq "$(cat "$C/check-calls")" "tick" "wwan-recover on a $kind session with a cleanup mark"
    rm -f "$CL_DIR/cleanup"
done
# a dry run decides nothing and starts nothing
: >"$C/check-calls"
lw_session v6child
DRYRUN=1 "$WR" >/dev/null 2>&1 || :
lw_expect_eq "$(cat "$C/check-calls")" "" "wwan-recover with DRYRUN"
echo ok
