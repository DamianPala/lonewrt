# R44a, D59: first boot sets nlbwmon up so that the month's data survives a restart of the router:
# the database sits on flash (not in RAM), is committed once a day, and the hotplug script restarts
# the daemon once per boot after the first NTP sync. The daemon is the fake of tests/notify/stubs
# (it commits on stop and restores on start, as read from the 25.12.6 binary).
# shellcheck source=tests/firstboot/fb-lib
. /fw/tests/firstboot/fb-lib
fb_prepare generic
PATH=/fw/tests/notify/stubs:$PATH
SYSLOG=$LW_TEST/syslog

# an init script like the package's, so the enable loop of zz-lw-config has something to enable
cat >/etc/init.d/nlbwmon <<'EOF'
#!/bin/sh /etc/rc.common
START=60
start() { :; }
EOF
chmod 755 /etc/init.d/nlbwmon
fb_uci_defaults

# the package's own settings stay, the three that matter change
fb_expect nlbwmon.@nlbwmon[0].database_directory /etc/nlbwmon
fb_expect nlbwmon.@nlbwmon[0].commit_interval 24h
fb_expect nlbwmon.@nlbwmon[0].database_interval 1
fb_expect nlbwmon.@nlbwmon[0].refresh_interval 30s
fb_expect nlbwmon.@nlbwmon[0].database_generations 10
fb_expect nlbwmon.@nlbwmon[0].database_limit 10000
fb_expect nlbwmon.@nlbwmon[0].local_network "192.168.0.0/16 172.16.0.0/12 10.0.0.0/8 lan"
lw_expect_eq "$(uci show nlbwmon | grep -c '=nlbwmon$')" 1 "nlbwmon sections"
[ -d /etc/nlbwmon ] || lw_fail "the database directory does not exist"
ls /etc/rc.d/S*nlbwmon >/dev/null 2>&1 || lw_fail "nlbwmon is not enabled"

# a second run changes nothing (no second section, no other value)
first=$(fb_state)
fb_uci_defaults
lw_expect_eq "$(fb_state)" "$first" "state after a second uci-defaults run"
lw_expect_eq "$(uci show nlbwmon | grep -c '=nlbwmon$')" 1 "nlbwmon sections after a second run"

# an image without the package config file (no nlbwmon in the build) still gets a working one
rm -f /etc/config/nlbwmon /etc/init.d/nlbwmon /etc/rc.d/*nlbwmon
fb_uci_defaults
fb_expect nlbwmon.@nlbwmon[0].database_directory /etc/nlbwmon
lw_expect_eq "$(uci show nlbwmon | grep -c '=nlbwmon$')" 1 "nlbwmon sections without the package file"

# --- the month survives a restart of the router
cp /fw/tests/notify/stubs/nlbwmon-init /etc/init.d/nlbwmon
chmod 755 /etc/init.d/nlbwmon
HOOK=/etc/hotplug.d/ntp/30-lw-nlbwmon
[ -x "$HOOK" ] || lw_fail "no ntp hotplug script for nlbwmon"
data() { nlbw -c json -g mac; }
reboot_hw() { lw_reboot_sim 30; /etc/init.d/nlbwmon start; }

/etc/init.d/nlbwmon start
echo "aa:bb:cc:00:00:01 40000000000 2000000000" >/tmp/nlbw-mem
# the shutdown: procd stops the daemon, it commits
/etc/init.d/nlbwmon stop
reboot_hw
case $(data) in
    *'"aa:bb:cc:00:00:01",3,40000000000,7,2000000000'*) ;;
    *) lw_fail "the month's data is gone after a restart: $(data)" ;;
esac

# the contrast: the package default directory is RAM and loses everything
uci set nlbwmon.@nlbwmon[0].database_directory=/var/lib/nlbwmon
uci commit nlbwmon
echo "aa:bb:cc:00:00:01 40000000000 2000000000" >/tmp/nlbw-mem
/etc/init.d/nlbwmon stop
reboot_hw
data >/dev/null 2>&1 && [ "$(data | grep -c 40000000000)" = 0 ] ||
    lw_fail "the database in /var survived a restart: the contrast test does not show anything"
uci set nlbwmon.@nlbwmon[0].database_directory=/etc/nlbwmon
uci commit nlbwmon

# --- the hotplug script: once per boot, only on the first sync, only for a daemon that is enabled
calls() { if [ -f "$LW_TEST/nlbwmon-calls" ]; then grep -c '^restart$' "$LW_TEST/nlbwmon-calls" || :; else echo 0; fi; }
: >"$LW_TEST/nlbwmon-calls"
rm -f /tmp/lw-nlbwmon-restarted
ACTION=step sh "$HOOK"
ACTION=unsync sh "$HOOK"
lw_expect_eq "$(calls)" 0 "restarts on other ntp events"
echo "aa:bb:cc:00:00:01 100 200" >/tmp/nlbw-mem
ACTION=stratum sh "$HOOK"
lw_expect_eq "$(calls)" 1 "restarts on the first stratum"
lw_expect_grep "$SYSLOG" "lw-nlbwmon: restarted after the first NTP sync of this boot"
ACTION=stratum sh "$HOOK"
ACTION=stratum sh "$HOOK"
lw_expect_eq "$(calls)" 1 "restarts on the next stratum events of the same boot"
case $(data) in
    *'"aa:bb:cc:00:00:01",3,100,7,200'*) ;;
    *) lw_fail "the restart lost the data: $(data)" ;;
esac
# a new boot: once more
lw_reboot_sim 30
ACTION=stratum sh "$HOOK"
lw_expect_eq "$(calls)" 2 "restarts after the next boot"
# no daemon in the image (script missing): nothing, no error
rm -f /tmp/lw-nlbwmon-restarted /etc/init.d/nlbwmon
ACTION=stratum sh "$HOOK" || lw_fail "the hotplug script failed without the init script"
[ ! -e /tmp/lw-nlbwmon-restarted ] || lw_fail "marker without a daemon"
echo ok
