# First boot with the rendered overlays of tests/build/30-render.sh (R7 table row
# "powiadomienia", R38a): the full profile puts token, chat and threshold into uci lonewrt.notify,
# readable by root only; the generic profile leaves them unset, the crontab without the balance line and the
# init script without an instance; a profile with only one of token and chat gives one syslog entry.
# shellcheck source=tests/firstboot/fb-lib
. /fw/tests/firstboot/fb-lib

# start_instances: what start_service of the init script asks procd for
start_instances() {
    (
        procd_open_instance() { echo open; }
        procd_set_param() { :; }
        procd_close_instance() { :; }
        # shellcheck source=src/files/etc/init.d/lw-notify
        . /etc/init.d/lw-notify
        start_service
    )
}

fb_prepare fake-full
fb_uci_defaults
fb_expect lonewrt.notify.token 987654321:FAKEtgtokenq7x9-ZZZZZZZZZZZZZZZZZZZZZZZZZ
fb_expect lonewrt.notify.chat -1009977001977
fb_expect lonewrt.notify.low_balance 7.50
fb_expect lonewrt.modem.bands 1,3,8,20,28,32
case $(ls -l /etc/config/lonewrt) in
    -rw-------*) ;;
    *) lw_fail "/etc/config/lonewrt: $(ls -l /etc/config/lonewrt)" ;;
esac
[ ! -e /etc/lw-notify.partial ] || lw_fail "partial marker with both keys"
grep -qxF '0 10 * * 1 /usr/sbin/lw-notify balance' /etc/crontabs/root ||
    lw_fail "full crontab lacks the balance cron line"
lw_expect_eq "$(start_instances)" open "procd instances with both keys"

# the generic image's first-boot script and crontab on the same router (a flash of the other image)
cp "$RENDER/generic/etc/uci-defaults/zz-lw-config" /etc/uci-defaults/
cp "$RENDER/generic/etc/crontabs/root" /etc/crontabs/root
fb_uci_defaults
for o in token chat low_balance; do fb_expect lonewrt.notify.$o "<unset>"; done
[ ! -e /etc/lw-notify.partial ] || lw_fail "partial marker without keys"
! grep -q lw-notify /etc/crontabs/root || lw_fail "generic crontab runs lw-notify"
lw_expect_eq "$(start_instances)" "" "procd instances without keys"
lw_expect_eq "$(grep -c lw-notify "$LW_TEST/syslog" || :)" 0 "lw-notify syslog entries without keys"

# only the chat set: one entry when the service is started, none on the next start
sed "s/^P_TG_CHAT_ID=''$/P_TG_CHAT_ID='-1001234'/" "$RENDER/generic/etc/uci-defaults/zz-lw-config" \
    >/etc/uci-defaults/zz-lw-config
fb_uci_defaults
fb_expect lonewrt.notify.chat -1001234
[ -e /etc/lw-notify.partial ] || lw_fail "no partial marker with one key"
lw_expect_eq "$(start_instances)" "" "procd instances with one key"
lw_expect_eq "$(start_instances)" "" "procd instances with one key, second start"
lw_expect_eq "$(grep -c 'lw-notify: notifications off' "$LW_TEST/syslog")" 1 "partial-key entries"
echo ok
