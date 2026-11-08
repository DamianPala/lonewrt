#!/usr/bin/env bash
# Notification keys in rendered overlays (SPEC R3, R4, R7 table rows "cron" and "powiadomienia",
# R35, R38a): the generic overlay has empty keys and the crontab of the sources (no balance line); a
# profile with token, chat and threshold gets the keys into zz-lw-config and the Monday 10:00
# balance line; a profile with only one of token and chat, or a threshold without them, builds with
# notifications off and no balance line, and only the one-key case leaves the first-boot log marker.
# R42: the heartbeat cron line (every 5 minutes) is there when HC_PING_URL is set, whatever the
# Telegram keys are, and only then; the address itself is only in zz-lw-config.
# shellcheck source=tests/build/lib.bash
source "$(dirname "$0")/lib.bash"
scratch notify
P=$SCRATCH/profiles
make_profiles "$P"
UD=etc/uci-defaults/zz-lw-config
CRON=etc/crontabs/root
BALANCE='0 10 * * 1 /usr/sbin/lw-notify balance'
BEAT='*/5 * * * * /usr/sbin/lw-heartbeat'
HC='https://hc-ping.fake-q7x9.example/FAKEhcping-q7x9-0001'

render() {
    LW_PROFILES=$P "$FW/build.sh" --render-only "$1" "$SCRATCH/$1" 2>"$SCRATCH/$1.err" && return 0
    cat "$SCRATCH/$1.err" >&2
    return 1
}
variant() { sed "$2" "$P/fake-full.conf" >"$P/$1.conf"; }

render generic
D=$SCRATCH/generic
cmp -s "$D/$CRON" "$FW/src/files/$CRON" || fail "generic crontab differs from the sources"
! grep -q lw-notify "$D/$CRON" || fail "generic crontab runs lw-notify"
! grep -q lw-heartbeat "$D/$CRON" || fail "generic crontab runs lw-heartbeat"
grep -qx "P_HC_PING_URL=''" "$D/$UD" || fail "generic zz-lw-config has a value for HC_PING_URL"
grep -q 'heartbeat: off$' "$SCRATCH/generic.err" || fail "render note: $(cat "$SCRATCH/generic.err")"
for k in TG_BOT_TOKEN TG_CHAT_ID LOW_BALANCE; do
    grep -qx "P_$k=''" "$D/$UD" || fail "generic zz-lw-config has a value for $k"
done
grep -q 'notifications: off$' "$SCRATCH/generic.err" ||
    fail "render note: $(cat "$SCRATCH/generic.err")"
[ -x "$D/etc/init.d/lw-notify" ] || fail "generic overlay lacks the init script"
[ "$(stat -c %a "$D/usr/lib/lw/notify.sh")" = 644 ] || fail "notify.sh is not 0644"
[ "$(stat -c %a "$D/usr/sbin/lw-notify")" = 755 ] || fail "lw-notify is not executable"

# R47, R48: the operator preset of the SIM card travels in every overlay as a plain data file, the
# helper libraries are there, and the router name goes to uci
[ -f "$D/usr/share/lw/operators/29702" ] || fail "generic overlay lacks the 29702 preset"
[ "$(stat -c %a "$D/usr/share/lw/operators/29702")" = 644 ] || fail "preset 29702 is not 0644"
cmp -s "$D/usr/share/lw/operators/29702" "$FW/src/files/usr/share/lw/operators/29702" ||
    fail "preset 29702 differs from the sources"
for f in operators.sh multipart.sh; do
    [ "$(stat -c %a "$D/usr/lib/lw/$f")" = 644 ] || fail "$f is not 0644"
done
grep -qx "P_ROUTER_NAME='Router'" "$D/$UD" || fail "generic zz-lw-config: router name"
# shellcheck disable=SC2016  # the $ belongs to the script under test
grep -qF 'uci set lonewrt.notify.router_name="$P_ROUTER_NAME"' "$D/$UD" ||
    fail "zz-lw-config does not write lonewrt.notify.router_name"

# R46: the SMS admin list is a plain value in zz-lw-config, empty in the generic overlay, and adds
# nothing to the crontab or the render notes
grep -qx "P_SMS_ADMINS=''" "$D/$UD" || fail "generic zz-lw-config has a value for SMS_ADMINS"
# shellcheck disable=SC2016  # the $ belongs to the script under test
grep -qF 'set_or_delete lonewrt.notify.sms_admins "$P_SMS_ADMINS"' "$D/$UD" ||
    fail "zz-lw-config does not write lonewrt.notify.sms_admins"

# R46b: the REBOOT limits are in every overlay with the profile's value (the generic ones are the
# defaults) and zz-lw-config puts them into uci
grep -qx "P_SMS_REBOOT_MAX_AGE_MIN='10'" "$D/$UD" || fail "generic zz-lw-config: REBOOT age"
grep -qx "P_SMS_REBOOT_MAX_PER_DAY='5'" "$D/$UD" || fail "generic zz-lw-config: REBOOT per day"
# shellcheck disable=SC2016  # the $ belongs to the script under test
grep -qF 'uci set lonewrt.notify.sms_reboot_max_age="$P_SMS_REBOOT_MAX_AGE_MIN"' "$D/$UD" ||
    fail "zz-lw-config does not write lonewrt.notify.sms_reboot_max_age"
# shellcheck disable=SC2016
grep -qF 'uci set lonewrt.notify.sms_reboot_max_day="$P_SMS_REBOOT_MAX_PER_DAY"' "$D/$UD" ||
    fail "zz-lw-config does not write lonewrt.notify.sms_reboot_max_day"

render fake-full
R=$SCRATCH/fake-full
grep -qx "P_SMS_REBOOT_MAX_AGE_MIN='15'" "$R/$UD" || fail "full zz-lw-config lacks the REBOOT age"
grep -qx "P_SMS_REBOOT_MAX_PER_DAY='3'" "$R/$UD" || fail "full zz-lw-config lacks the REBOOT limit"
grep -qxF "P_SMS_ADMINS='+15550100123,15550100456'" "$R/$UD" ||
    fail "full zz-lw-config lacks the SMS admins"
! grep -qF 15550100123 "$SCRATCH/fake-full.err" "$R/$CRON" ||
    fail "the SMS admins leaked to the notes or the crontab"
grep -qxF "$BALANCE" "$R/$CRON" || fail "full crontab lacks the balance cron line"
grep -qxF "$BEAT" "$R/$CRON" || fail "full crontab lacks the heartbeat line"
[ "$(grep -c lw-heartbeat "$R/$CRON")" = 1 ] || fail "full crontab has the heartbeat line twice"
! grep -qF hc-ping "$R/$CRON" || fail "the heartbeat address is in the crontab"
grep -qxF "P_HC_PING_URL='$HC'" "$R/$UD" || fail "full zz-lw-config lacks the heartbeat address"
grep -q 'heartbeat: on$' "$SCRATCH/fake-full.err" || fail "render note: $(cat "$SCRATCH/fake-full.err")"
! grep -qF FAKEhcping "$SCRATCH/fake-full.err" || fail "render output shows the heartbeat address"
lw_lines=$(grep -vxF -e "$BALANCE" -e "$BEAT" "$R/$CRON")
[ "$lw_lines" = "$(cat "$FW/src/files/$CRON")" ] || fail "full crontab changed other lines"
grep -qxF "P_TG_BOT_TOKEN='987654321:FAKEtgtokenq7x9-ZZZZZZZZZZZZZZZZZZZZZZZZZ'" "$R/$UD" ||
    fail "full zz-lw-config lacks the token"
grep -qxF "P_TG_CHAT_ID='-1009977001977'" "$R/$UD" || fail "full zz-lw-config lacks the chat"
grep -qxF "P_LOW_BALANCE='7.50'" "$R/$UD" || fail "full zz-lw-config lacks the threshold"
grep -q 'notifications: on, weekly balance check$' "$SCRATCH/fake-full.err" ||
    fail "render note: $(cat "$SCRATCH/fake-full.err")"
! grep -qF FAKEtgtokenq7x9 "$SCRATCH/fake-full.err" || fail "render output shows the token"

# without a threshold: notifications, no weekly balance check (R36)
variant no-low "s/^LOW_BALANCE=.*/LOW_BALANCE=''/"
render no-low
! grep -q "lw-notify balance" "$SCRATCH/no-low/$CRON" || fail "balance line without a threshold"
grep -qxF "$BEAT" "$SCRATCH/no-low/$CRON" || fail "no heartbeat line without a threshold"

# one key only, or a threshold alone: builds, notifications off, no balance cron line (R38a)
variant token-only "s/^TG_CHAT_ID=.*/TG_CHAT_ID=''/"
variant chat-only "s/^TG_BOT_TOKEN=.*/TG_BOT_TOKEN=''/"
variant low-only "s/^TG_BOT_TOKEN=.*/TG_BOT_TOKEN=''/;s/^TG_CHAT_ID=.*/TG_CHAT_ID=''/"
# (the heartbeat does not depend on them: its line is the only one added)
for v in token-only chat-only low-only; do
    render "$v" || fail "profile $v did not build: $(cat "$SCRATCH/$v.err")"
    grep -vxF "$BEAT" "$SCRATCH/$v/$CRON" | cmp -s - "$FW/src/files/$CRON" ||
        fail "$v crontab differs from the sources"
    grep -qxF "$BEAT" "$SCRATCH/$v/$CRON" || fail "$v crontab lacks the heartbeat line"
done
grep -q 'notifications: off (only one of TG_BOT_TOKEN and TG_CHAT_ID is set)$' \
    "$SCRATCH/token-only.err" || fail "render note: $(cat "$SCRATCH/token-only.err")"
grep -q 'notifications: off$' "$SCRATCH/low-only.err" ||
    fail "render note: $(cat "$SCRATCH/low-only.err")"

# R42: no address, no heartbeat line, whatever the Telegram keys are
variant no-hc "s/^HC_PING_URL=.*/HC_PING_URL=''/"
render no-hc
grep -qx "P_HC_PING_URL=''" "$SCRATCH/no-hc/$UD" || fail "no-hc zz-lw-config has an address"
! grep -q lw-heartbeat "$SCRATCH/no-hc/$CRON" || fail "heartbeat line without an address"
grep -qxF "$BALANCE" "$SCRATCH/no-hc/$CRON" || fail "no-hc lost the balance cron line"
grep -q 'heartbeat: off$' "$SCRATCH/no-hc.err" || fail "render note: $(cat "$SCRATCH/no-hc.err")"
variant hc-only "s/^TG_BOT_TOKEN=.*/TG_BOT_TOKEN=''/;s/^TG_CHAT_ID=.*/TG_CHAT_ID=''/;s/^LOW_BALANCE=.*/LOW_BALANCE=''/"
render hc-only
grep -qxF "$BEAT" "$SCRATCH/hc-only/$CRON" || fail "no heartbeat line without Telegram keys"
echo ok
