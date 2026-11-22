# R63d, R64 and the interface facts of the Tailscale section: the state file the service writes for
# the bot (not_added, added, ended, starting, not_running, with the fields of the contract) and the
# one syslog line per change of the state, in ASCII, without a link or a key.
# shellcheck source=tests/tailscale/ts.inc
. /fw/tests/tailscale/ts.inc
ts_setup

rc=0
lw-tailscale status >/dev/null || rc=$?
lw_expect_eq "$rc" 3 "status before the service has written a file"

# no daemon
ts_once
lw_expect_eq "$(ts_st state)" not_running "state without a daemon"
lw_expect_eq "$(ts_st name)$(ts_st ip)$(ts_st account)$(ts_st expiry)" "" "fields without a daemon"
lw_expect_eq "$(ts_st route)" none "route without a daemon"
lw_expect_eq "$(ts_st updated)" $BASE "updated"
lw_expect_eq "$(ts_syslog)" "state: not running" "first syslog line"

# a daemon that wants a login, nothing recorded: not added
ts_backend NeedsLogin
ts_once
lw_expect_eq "$(ts_st state)" not_added "state of a fresh router"
ts_once
lw_expect_eq "$(ts_syslog | tr '\n' '|')" "state: not running|state: not added|" "no line without a change"

# starting is a passage: shown in the file, not in the log
ts_backend Starting
ts_once
lw_expect_eq "$(ts_st state)" starting "state while starting"
lw_expect_eq "$(ts_syslog | wc -l)" 2 "starting writes no line"

# added: every field; the address is the 100.x one, the name the short one
ts_added $((BASE + 100 * 86400))
ts_once
lw_expect_eq "$(ts_st state)" added "state of an added router"
lw_expect_eq "$(ts_st name)" rtr "name"
lw_expect_eq "$(ts_st ip)" 100.64.0.5 "address"
lw_expect_eq "$(ts_st account)" owner@example.com "account"
lw_expect_eq "$(ts_st expiry)" $((BASE + 100 * 86400)) "expiry"
lw_expect_eq "$(ts_st expiry_off)" 0 "expiry_off with a date"
lw_expect_eq "$(ts_st route)" none "route without advertise_lan"
lw_expect_eq "$(ts_st prefix)" "" "prefix without advertise_lan"

# no date: key expiry is off; the zero time and a date with an offset and fraction
ts_added
ts_once
lw_expect_eq "$(ts_st expiry_off)$(ts_st expiry)" "1" "key expiry off, no date"
echo 0001-01-01T00:00:00Z >"$D/keyexpiry"
ts_once
lw_expect_eq "$(ts_st expiry_off)$(ts_st expiry)" "1" "zero time is key expiry off"
echo 2030-04-01T14:00:00.123456789+02:00 >"$D/keyexpiry"
ts_once
lw_expect_eq "$(ts_st expiry)" "$(date -u -d '2030-04-01 12:00:00' +%s)" "date with offset and fraction"
echo 2030-04-01T09:30:00-02:30 >"$D/keyexpiry"
ts_once
lw_expect_eq "$(ts_st expiry)" "$(date -u -d '2030-04-01 12:00:00' +%s)" "date with a negative offset"
echo garbage >"$D/keyexpiry"
ts_once
lw_expect_eq "$(ts_st expiry_off)$(ts_st expiry)" "0" "an unreadable date is neither a date nor off"

# the route of the LAN (R67)
uci set lonewrt.tailscale.advertise_lan=1
uci commit lonewrt
ts_added $((BASE + 100 * 86400))
ts_once
lw_expect_eq "$(ts_st route)" pending "route offered, not approved"
lw_expect_eq "$(ts_st prefix)" 192.168.5.0/24 "prefix"
echo '10.9.9.0/24' >"$D/routes"
ts_once
lw_expect_eq "$(ts_st route)" pending "another route is not this one"
echo '192.168.5.0/24' >"$D/routes"
ts_once
lw_expect_eq "$(ts_st route)" approved "route approved"

# the sign-in ends, then the daemon stops
ts_backend NeedsLogin
ts_once
lw_expect_eq "$(ts_st state)" ended "state after an added router wants a login"
lw_expect_eq "$(ts_st name)$(ts_st ip)$(ts_st route)" "none" "fields of an ended router"
ts_backend Stopped
ts_once
lw_expect_eq "$(ts_st state)" not_running "Stopped is not running"

lw_expect_eq "$(ts_syslog | tr '\n' '|')" \
    "state: not running|state: not added|state: added|state: sign-in ended|state: not running|" "syslog lines"
lw_expect_eq "$(ts_syslog | wc -l)" 5 "one line per change"

# R63d, R65f: ASCII, no link, no key, nothing left half written
ts_down
rm -f "$D/authurl"
echo https://login.example.invalid/a/FAKELINK01 >"$D/authurl"
ts_backend NeedsLogin
ts_key
ts_once
for f in "$T/syslog" /tmp/lw-tailscale/state; do
    [ "$(tr -d '\011\012\040-\176' <"$f" | wc -c)" = 0 ] || lw_fail "non-ASCII bytes in $f"
    lw_expect_no_grep "$f" "http"
    lw_expect_no_grep "$f" "tskey"
done
lw_expect_eq "$(ls /tmp/lw-tailscale)" "logged
state" "files of the service in RAM"
lw_expect_eq "$(cut -d= -f1 /tmp/lw-tailscale/state | tr '\n' ' ')" \
    "state name ip account expiry expiry_off route prefix updated " "keys of the state file"
echo ok
