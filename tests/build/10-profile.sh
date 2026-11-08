#!/usr/bin/env bash
# SPEC R3: a missing key, an empty value where none is allowed, a quote inside a value, an unknown
# key or a malformed value stops the build with the key's name, before ImageBuilder runs, and leaves
# image/ without a new file. Errors never echo a profile value.
# shellcheck source=tests/build/lib.bash
source "$(dirname "$0")/lib.bash"
scratch profile
P=$SCRATCH/profiles
I=$SCRATCH/image
make_profiles "$P"
mkdir -p "$I"
before=$(listing "$I")

build() { LW_PROFILES=$P LW_IMAGE=$I "$FW/build.sh" "$@"; }
# variant NAME SED_EXPRESSION: the fake full profile with one line changed
variant() { sed "$2" "$P/fake-full.conf" >"$P/$1.conf"; }

variant no-lan '/^LAN_IP=/d'
expect_fail_with "key LAN_IP is missing" build no-lan

variant empty-host "s/^HOSTNAME=.*/HOSTNAME=''/"
expect_fail_with "key HOSTNAME is empty" build empty-host

variant empty-wg-enabled "s/^WG_ENABLED=.*/WG_ENABLED=''/"
expect_fail_with "key WG_ENABLED is empty" build empty-wg-enabled

variant quote "s/^WIFI_SSID=.*/WIFI_SSID='it's'/"
expect_fail_with "quote.conf line" build quote

variant unknown "\$a LAN_IPP='10.1.1.1'"
expect_fail_with "unknown key LAN_IPP" build unknown

variant twice "\$a HOSTNAME='again'"
expect_fail_with "key HOSTNAME appears twice" build twice

variant short-key "s/^WIFI_KEY=.*/WIFI_KEY='shortpw'/"
expect_fail_with "key WIFI_KEY has an invalid value" build short-key
err=$(build short-key 2>&1 || true)
! grep -qF shortpw <<<"$err" || fail "error message echoes the WiFi key"

variant wg-no-key "s/^WG_PRIVATE_KEY=.*/WG_PRIVATE_KEY=''/"
expect_fail_with "key WG_PRIVATE_KEY is empty but WG_ENABLED is 1" build wg-no-key

# A profile from before the notifications (SPEC R3: the owner adds the keys himself)
variant no-tg '/^TG_BOT_TOKEN=/d'
expect_fail_with "key TG_BOT_TOKEN is missing" build no-tg
variant bad-token "s/^TG_BOT_TOKEN=.*/TG_BOT_TOKEN='badtoken-q7x9'/"
expect_fail_with "key TG_BOT_TOKEN has an invalid value" build bad-token
err=$(build bad-token 2>&1 || true)
! grep -qF badtoken-q7x9 <<<"$err" || fail "error message echoes the bot token"
variant bad-chat "s/^TG_CHAT_ID=.*/TG_CHAT_ID='@channel'/"
expect_fail_with "key TG_CHAT_ID has an invalid value" build bad-chat
variant bad-low "s/^LOW_BALANCE=.*/LOW_BALANCE='7,50'/"
expect_fail_with "key LOW_BALANCE has an invalid value" build bad-low
# the old name is an unknown key now
variant old-low "s/^LOW_BALANCE=/LOW_BALANCE_EUR=/"
expect_fail_with "unknown key LOW_BALANCE_EUR" build old-low

# R42: the heartbeat address is a key like the others; a plain-http address, spaces or a quote stop
# the build, and the error never shows the address
variant no-hc '/^HC_PING_URL=/d'
expect_fail_with "key HC_PING_URL is missing" build no-hc
variant http-hc "s|^HC_PING_URL=.*|HC_PING_URL='http://hc-ping.fake-q7x9.example/FAKEhcping-q7x9-0001'|"
expect_fail_with "key HC_PING_URL has an invalid value" build http-hc
variant space-hc "s|^HC_PING_URL=.*|HC_PING_URL='https://hc-ping.fake-q7x9.example/FAKEhcping q7x9'|"
expect_fail_with "key HC_PING_URL has an invalid value" build space-hc
variant quote-hc "s|^HC_PING_URL=.*|HC_PING_URL='https://hc-ping.fake-q7x9.example/FAKEhc'ping'|"
expect_fail_with "quote-hc.conf line" build quote-hc
for v in http-hc space-hc quote-hc; do
    err=$(build $v 2>&1 || true)
    ! grep -qF FAKEhc <<<"$err" || fail "error message of $v echoes the heartbeat address"
done

# R46: SMS_ADMINS is a comma list of numbers, each with an optional + and 6 to 15 digits, no
# spaces; anything else stops the build, and the error never shows the list
variant no-sms '/^SMS_ADMINS=/d'
expect_fail_with "key SMS_ADMINS is missing" build no-sms
i=0
for bad in 'abc' '+1555 0100123' '12345' '1234567890123456' '+1555010012,' ',15550100123' \
    '15550100123,,15550100456' '15550100123, 15550100456' '++15550100123' '1555+0100123' \
    '+15550100123;15550100456' '+15550100123,15x50100456' '+' '１５５５０１００１２３'; do
    i=$((i + 1))
    variant "bad-sms-$i" "s|^SMS_ADMINS=.*|SMS_ADMINS='$bad'|"
    expect_fail_with "key SMS_ADMINS has an invalid value" build "bad-sms-$i"
    err=$(build "bad-sms-$i" 2>&1 || true)
    ! grep -qF -- "$bad" <<<"$err" || fail "error message echoes the SMS_ADMINS value '$bad'"
done
i=0
for good in '+15550100123' '15550100456' '+15550100123,15550100456' '123456' '123456789012345' \
    '+123456,00123456789,+123456789012345'; do
    i=$((i + 1))
    variant "good-sms-$i" "s|^SMS_ADMINS=.*|SMS_ADMINS='$good'|"
    build --render-only "good-sms-$i" "$SCRATCH/good-sms-$i" 2>/dev/null ||
        fail "SMS_ADMINS '$good' was rejected"
    grep -qxF "P_SMS_ADMINS='$good'" "$SCRATCH/good-sms-$i/etc/uci-defaults/zz-lw-config" ||
        fail "SMS_ADMINS '$good' not written verbatim"
done

# R48: ROUTER_NAME is required, 1 to 20 characters, ASCII letters and digits, space and -, and starts
# with a letter or digit; anything else stops the build, and the error never shows the value
variant no-name '/^ROUTER_NAME=/d'
expect_fail_with "key ROUTER_NAME is missing" build no-name
variant empty-name "s/^ROUTER_NAME=.*/ROUTER_NAME=''/"
expect_fail_with "key ROUTER_NAME is empty" build empty-name
i=0
for bad in '123456789012345678901' ' lead' '-lead' 'semi;colon' 'dot.dot' 'under_score' 'qu"ote' \
    'back`tick' 'dollar$x' 'Zażółć' 'ＲＨ' '１２３' 'tab	tab' 'slash/x' 'colon:x' 'ŁÓDŹ'; do
    i=$((i + 1))
    variant "bad-name-$i" "s|^ROUTER_NAME=.*|ROUTER_NAME='$bad'|"
    expect_fail_with "key ROUTER_NAME has an invalid value" build "bad-name-$i"
    err=$(build "bad-name-$i" 2>&1 || true)
    ! grep -qF -- "$bad" <<<"$err" || fail "error message echoes the ROUTER_NAME value '$bad'"
done
i=0
for good in 'R' 'Home router' 'Router' 'a-b c-1' '12345678901234567890' 'Trailing ' 'x-'; do
    i=$((i + 1))
    variant "good-name-$i" "s|^ROUTER_NAME=.*|ROUTER_NAME='$good'|"
    build --render-only "good-name-$i" "$SCRATCH/good-name-$i" 2>/dev/null ||
        fail "ROUTER_NAME '$good' was rejected"
    grep -qxF "P_ROUTER_NAME='$good'" "$SCRATCH/good-name-$i/etc/uci-defaults/zz-lw-config" ||
        fail "ROUTER_NAME '$good' not written verbatim"
done

# R46b: the two REBOOT limits are keys every profile must have, with a positive whole number of up to
# 4 ASCII digits; anything else stops the build, and the error never shows the value
for key in SMS_REBOOT_MAX_AGE_MIN SMS_REBOOT_MAX_PER_DAY; do
    variant "no-$key" "/^$key=/d"
    expect_fail_with "key $key is missing" build "no-$key"
    variant "empty-$key" "s/^$key=.*/$key=''/"
    expect_fail_with "key $key is empty" build "empty-$key"
    i=0
    for bad in 0 00 05 -1 1.5 ten 12345 '1 0' +5 ' 5' '５' '１０'; do
        i=$((i + 1))
        variant "bad-$key-$i" "s|^$key=.*|$key='$bad'|"
        expect_fail_with "key $key has an invalid value" build "bad-$key-$i"
        err=$(build "bad-$key-$i" 2>&1 || true)
        ! grep -qF -- "'$bad'" <<<"$err" || fail "error message echoes the $key value '$bad'"
    done
    for good in 1 5 10 60 9999; do
        variant "good-$key-$good" "s|^$key=.*|$key='$good'|"
        build --render-only "good-$key-$good" "$SCRATCH/good-$key-$good" 2>/dev/null ||
            fail "$key '$good' was rejected"
        grep -qxF "P_$key='$good'" "$SCRATCH/good-$key-$good/etc/uci-defaults/zz-lw-config" ||
            fail "$key '$good' not written verbatim"
    done
done

# Digits are ASCII digits only: fullwidth and Arabic-Indic digits are Unicode digits that a plain
# regex class \d would let through, and that uci, cron or the router's shell would not read as numbers
i=0
for pair in 'WIFI_CHANNEL_2G=１１' 'WIFI_CHANNEL_5G=٣٦' 'LTE_BANDS=３,２０' 'WG_ENDPOINT_PORT=５１８２０' \
    'WG_KEEPALIVE=２５' 'TG_CHAT_ID=-１００９９７７' 'LOW_BALANCE=７.５０' 'LAN_IP=192.168.７７.1' \
    'WG_ADDRESS=10.99.77.２/32' 'WG_ALLOWED_IPS=0.0.0.0/０' \
    'TG_BOT_TOKEN=９８７６５:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'; do
    i=$((i + 1))
    key=${pair%%=*}
    val=${pair#*=}
    variant "unicode-digit-$i" "s|^$key=.*|$key='$val'|"
    expect_fail_with "key $key has an invalid value" build "unicode-digit-$i"
    err=$(build "unicode-digit-$i" 2>&1 || true)
    ! grep -qF -- "$val" <<<"$err" || fail "error message echoes the $key value '$val'"
done

# The same checks guard --render-only
expect_fail_with "key LAN_IP is missing" build --render-only no-lan "$SCRATCH/render"
[ ! -e "$SCRATCH/render" ] || fail "--render-only left output after a profile error"

# Empty APN, bands, tunnel and notification fields are allowed (SPEC R3 exceptions)
sed -e "s/^\(WWAN_[A-Z]*\)=.*/\1=''/" -e "s/^LTE_BANDS=.*/LTE_BANDS=''/" \
    -e "s/^\(WG_[A-Z_]*\)=.*/\1=''/" -e "s/^WG_ENABLED=''/WG_ENABLED='0'/" \
    -e "s/^\(TG_[A-Z_]*\)=.*/\1=''/" -e "s/^LOW_BALANCE=.*/LOW_BALANCE=''/" \
    -e "s/^HC_PING_URL=.*/HC_PING_URL=''/" -e "s/^SMS_ADMINS=.*/SMS_ADMINS=''/" \
    "$P/fake-full.conf" >"$P/blanks.conf"
build --render-only blanks "$SCRATCH/blanks" 2>/dev/null || fail "allowed empty values were rejected"
grep -qx "P_SMS_ADMINS=''" "$SCRATCH/blanks/etc/uci-defaults/zz-lw-config" ||
    fail "an empty SMS_ADMINS is not written as empty"

[ "$(listing "$I")" = "$before" ] || fail "a failed build changed image/: $(listing "$I")"
echo ok
