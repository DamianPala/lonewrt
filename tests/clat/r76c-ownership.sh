# R76c: lw-clat-check takes away only what is the translation of wwan_6_4: a helper process is its
# own only when it is 464xlatcfg working on the device 464-wwan_6_4, and the rules it removes are the
# ones the stock script writes for that device's address (with their pref), never Tailscale's or
# another translation's.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/clat/helpers.inc
. /fw/tests/clat/helpers.inc

TS_RULES='from all fwmark 0x80000/0xff0000 lookup main pref 5210
from all fwmark 0x80000/0xff0000 lookup default pref 5230
from all fwmark 0x80000/0xff0000 unreachable pref 5250
from all lookup 52 pref 5270'
OTHER_RULES='to 2001:db8:2::99 lookup prelocal pref 0'

# a helper of another device (another translation, its number used again by chance) in the pid file:
# not ours, so not signalled; the pid file goes
cl_setup
cl_fake_helper 464-other0 wwan9 2001:db8:77::/96
echo "$FAKE" >"$CL_PID"
cl_tick
kill -0 "$FAKE" 2>/dev/null || lw_fail "a 464xlatcfg of another device was killed"
lw_expect_eq "$(cl_live)" 2 "the foreign helper lives, ours was made"
kill "$FAKE" 2>/dev/null || :
# ... and our own helper, with the right device, is
cl_setup
cl_fake_helper 464-wwan_6_4 wwan0 2001:db8:77::/96
echo "$FAKE" >"$CL_PID"
printf '{"up":false}\n' >"$T/ifstatus/wwan.json"
: >"$CL_DIR/active"
cl_tick
i=0
while kill -0 "$FAKE" 2>/dev/null && [ "$i" -lt 5 ]; do i=$((i + 1)); /bin/sleep 1; done
! kill -0 "$FAKE" 2>/dev/null || { kill "$FAKE"; lw_fail "our own helper was not stopped"; }
# the program's path may be anything that ends in 464xlatcfg (the stock helper is started by name
# and found through PATH): the whole field is what counts
cl_setup
CL_ARGV0=/usr/sbin/464xlatcfg cl_fake_helper 464-wwan_6_4 wwan0 2001:db8:77::/96
echo "$FAKE" >"$CL_PID"
printf '{"up":false}\n' >"$T/ifstatus/wwan.json"
: >"$CL_DIR/active"
cl_tick
i=0
while kill -0 "$FAKE" 2>/dev/null && [ "$i" -lt 5 ]; do i=$((i + 1)); /bin/sleep 1; done
! kill -0 "$FAKE" 2>/dev/null || { kill "$FAKE"; lw_fail "our own helper, started by path, was not stopped"; }
# a shell that only has the helper's name in its arguments is not a helper, in an argument of -c ...
cl_setup
setsid sh -c 'while :; do /bin/sleep 100; done' x 464xlatcfg 464-wwan_6_4 </dev/null >/dev/null 2>&1 &
FAKE=$!
/bin/sleep 1
echo "$FAKE" >"$CL_PID"
cl_tick
kill -0 "$FAKE" 2>/dev/null || lw_fail "a shell that only has the helper's name in its arguments was killed"
kill "$FAKE" 2>/dev/null || :
# ... and as a script with the helper's name in a path and the device after it (what the review found)
cl_setup
mkdir -p /tmp/other
printf '#!/bin/sh\nwhile :; do /bin/sleep 100; done\n' >/tmp/other/464xlatcfg
setsid sh /tmp/other/464xlatcfg 464-wwan_6_4 wwan0 2001:db8:77::/96 </dev/null >/dev/null 2>&1 &
FAKE=$!
/bin/sleep 1
echo "$FAKE" >"$CL_PID"
printf '{"up":false}\n' >"$T/ifstatus/wwan.json"
: >"$CL_DIR/active"
cl_tick
kill -0 "$FAKE" 2>/dev/null || lw_fail "a script /tmp/other/464xlatcfg run by sh was killed"
kill "$FAKE" 2>/dev/null || :
# the helper's name and device as arguments of another program name
cl_setup
CL_ARGV0=ucode cl_fake_helper 464xlatcfg 464-wwan_6_4 wwan0
echo "$FAKE" >"$CL_PID"
printf '{"up":false}\n' >"$T/ifstatus/wwan.json"
: >"$CL_DIR/active"
cl_tick
kill -0 "$FAKE" 2>/dev/null || lw_fail "a program that has 464xlatcfg and the device as arguments was killed"
kill "$FAKE" 2>/dev/null || :

# Tailscale's rules and another translation's rule stay through our teardown, whatever order
for end in ended v4; do
    cl_setup
    printf '%s\n' "$TS_RULES" >>"$C/rules"
    printf '%s\n' "$OTHER_RULES" >>"$C/rules"
    cl_tick
    cl_translated "setup with Tailscale's rules ($end)"
    before=$(cl_rules | sort)
    case $end in
        ended) printf '{"up":false}\n' >"$T/ifstatus/wwan.json" ;;
        v4) lw_session v4 ;;
    esac
    cl_tick
    # a tick on a session that is not IPv6-only is not what runs it; the event is
    cl_new
    lw_expect_eq "$(cl_live)" 0 "teardown ($end): helper"
    lw_expect_eq "$(cl_rules | sort)" "$(printf '%s\n%s\n%s\n' "$TS_RULES" "$OTHER_RULES" "$CL_RULE0" | sort)" \
        "teardown ($end): rules (before: $before)"
done

# another translation is up (its marker is there): our teardown leaves the local table where its
# setup put it
cl_setup
cl_tick
echo 2001:db8:2::99 >/tmp/clat/464-wwan_9_9-anycast
printf '%s\n' "$OTHER_RULES" >>"$C/rules"
printf '{"up":false}\n' >"$T/ifstatus/wwan.json"
cl_new
lw_expect_eq "$(cl_live)" 0 "another translation up: our helper"
lw_expect_eq "$(cl_rules | sort)" "$(printf '%s\n%s\n' "from all lookup local pref 1" "$OTHER_RULES" | sort)" \
    "another translation up: rules"
echo ok
