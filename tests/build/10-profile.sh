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
expect_fail_with "key LAN_IP is missing; copy it from generic.conf" build no-lan

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

# R61: SSH_KEYS is a key every profile must have, and it may be empty. A malformed entry stops the
# build with the key's name and the entry's number (1-based), and the error shows no part of the
# value. Whitespace around ';' goes, an empty entry (a;;b, a trailing or a leading ';') is malformed,
# the data must be base64 whose first field is the declared type.
variant no-ssh '/^SSH_KEYS=/d'
expect_fail_with "key SSH_KEYS is missing; add the line SSH_KEYS=''" build no-ssh
A_DATA=$(ssh_field "$FAKE_SSH_A" 2)
B_DATA=$(ssh_field "$FAKE_SSH_B" 2)
i=0
for spec in \
    '1|ssh-ed25519 not-base64' \
    '1|;' \
    '1| ' \
    "2|$FAKE_SSH_A;;$FAKE_SSH_B" \
    "2|$FAKE_SSH_A; ;$FAKE_SSH_B" \
    "2|$FAKE_SSH_A;" \
    "1|;$FAKE_SSH_A" \
    "2|$FAKE_SSH_A;ssh-ed25519 not-base64" \
    "3|$FAKE_SSH_A;$FAKE_SSH_B;ssh-ed25519" \
    "1|ssh-dss $A_DATA" \
    "1|ecdsa-sha2-nistp384 $A_DATA" \
    "1|$(ssh_field "$FAKE_SSH_E" 1) $A_DATA" \
    "1|ssh-rsa $A_DATA" \
    "1|ssh-ed25519" \
    "1|ssh-ed25519 AAAA" \
    "1|ssh-ed25519 ${A_DATA%+}" \
    "1|ssh-ed25519 ${A_DATA}= x" \
    "1|ssh-ed25519 AAAAC3NzaC1lZDI1NTE5.AAAAIDtj" \
    "1|$A_DATA ssh-ed25519" \
    "1|options ssh-ed25519 $A_DATA"; do
    i=$((i + 1))
    want=${spec%%|*}
    bad=${spec#*|}
    variant "bad-ssh-$i" "s|^SSH_KEYS=.*|SSH_KEYS='$bad'|"
    expect_fail_with "key SSH_KEYS entry $want is malformed" build "bad-ssh-$i"
    err=$(build "bad-ssh-$i" 2>&1 || true)
    for secret in not-base64 "$A_DATA" "$B_DATA" fake-a-q7x9; do
        ! grep -qF -- "$secret" <<<"$err" || fail "error message of bad-ssh-$i echoes part of SSH_KEYS ($secret)"
    done
done
i=0
for good in '' "$FAKE_SSH_A" "$FAKE_SSH_E" "$FAKE_SSH_R" "$FAKE_SSH_A;$FAKE_SSH_B" \
    "  $FAKE_SSH_A  ;  $FAKE_SSH_B  " "$(ssh_field "$FAKE_SSH_A" 1) $A_DATA" \
    "$(ssh_field "$FAKE_SSH_A" 1) $A_DATA two words and (dots.)"; do
    i=$((i + 1))
    variant "good-ssh-$i" "s|^SSH_KEYS=.*|SSH_KEYS='$good'|"
    build --render-only "good-ssh-$i" "$SCRATCH/good-ssh-$i" 2>/dev/null ||
        fail "SSH_KEYS case $i was rejected"
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

# R13e: WWAN_PIN is a key every profile must have; empty or 4 to 8 ASCII digits, anything else stops
# the build, and the error never shows the value. A PIN lands in the first-boot script as it is.
variant no-pin '/^WWAN_PIN=/d'
expect_fail_with "key WWAN_PIN is missing; add the line WWAN_PIN=''" build no-pin
i=0
for bad in 123 123456789 12a4 ' 1234' '1234 ' +1234 '12 34' 12.4 '１２３４'; do
    i=$((i + 1))
    variant "bad-pin-$i" "s|^WWAN_PIN=.*|WWAN_PIN='$bad'|"
    expect_fail_with "key WWAN_PIN has an invalid value" build "bad-pin-$i"
    err=$(build "bad-pin-$i" 2>&1 || true)
    ! grep -qF -- "'$bad'" <<<"$err" || fail "error message echoes the WWAN_PIN value '$bad'"
done
for good in 0000 1234 73914826; do
    variant "good-pin-$good" "s|^WWAN_PIN=.*|WWAN_PIN='$good'|"
    build --render-only "good-pin-$good" "$SCRATCH/good-pin-$good" 2>/dev/null ||
        fail "WWAN_PIN '$good' was rejected"
    grep -qxF "P_WWAN_PIN='$good'" "$SCRATCH/good-pin-$good/etc/uci-defaults/zz-lw-config" ||
        fail "WWAN_PIN '$good' not written verbatim"
done

# R47d: the OP_ keys carry one operator preset. With all of them empty the image has only its own
# presets. With one set, all but OP_SHORT_CODES must be set, and the router's own reader judges the
# values: a refusal names the key and never shows the value. A good set lands as the data file
# /usr/share/lw/operators/<OP_MCCMNC>, also in place of a preset of the image.
variant no-op '/^OP_NAME=/d'
expect_fail_with "key OP_NAME is missing; add the line OP_NAME=''" build no-op
build --render-only fake-full "$SCRATCH/op-full" 2>"$SCRATCH/op-full.err" ||
    fail "R47d: the fixture's OP_ keys were refused: $(tail -n 2 "$SCRATCH/op-full.err")"
preset=$SCRATCH/op-full/usr/share/lw/operators/99977
[ -f "$preset" ] || fail "R47d: no preset file from the OP_ keys"
[ "$(stat -c %a "$preset")" = 644 ] || fail "R47d: the preset file is not 0644"
diff <(printf '%s\n' "OPERATOR_NAME='Acme-q7x9'" "CURRENCY='USD'" "BALANCE_QUERY_NUMBER='4040'" \
    "BALANCE_QUERY_TEXT='BAL'" "BALANCE_REPLY_FROM='ACME'" \
    "BALANCE_REPLY_PATTERN='Your balance is {amount} USD, valid till {month}/{day}'" \
    "SHORT_CODES='4040 4041'") "$preset" >/dev/null || fail "R47d: the preset file differs from the OP_ keys"
cmp -s "$SCRATCH/op-full/usr/share/lw/operators/29702" "$FW/src/files/usr/share/lw/operators/29702" ||
    fail "R47d: the image's own preset changed"
grep -q 'operator preset: from the profile' "$SCRATCH/op-full.err" || fail "R47d: no render note about the preset"
variant op-nocodes "s/^OP_SHORT_CODES=.*/OP_SHORT_CODES=''/"
build --render-only op-nocodes "$SCRATCH/op-nocodes" 2>/dev/null || fail "R47d: an empty OP_SHORT_CODES was refused"
! grep -q SHORT_CODES "$SCRATCH/op-nocodes/usr/share/lw/operators/99977" ||
    fail "R47d: an empty OP_SHORT_CODES wrote a line"
variant op-own "s/^OP_MCCMNC=.*/OP_MCCMNC='29702'/"
build --render-only op-own "$SCRATCH/op-own" 2>/dev/null || fail "R47d: a preset for 29702 was refused"
grep -qx "OPERATOR_NAME='Acme-q7x9'" "$SCRATCH/op-own/usr/share/lw/operators/29702" ||
    fail "R47d: the profile's preset did not replace the image's"
for key in OP_MCCMNC OP_NAME OP_CURRENCY OP_BALANCE_QUERY_NUMBER OP_BALANCE_QUERY_TEXT \
    OP_BALANCE_REPLY_FROM OP_BALANCE_REPLY_PATTERN; do
    variant "op-empty-$key" "s|^$key=.*|$key=''|"
    expect_fail_with "key $key is empty but another OP_ key is set" build "op-empty-$key"
done
i=0
while IFS='=' read -r key bad; do
    i=$((i + 1))
    variant "op-bad-$i" "s|^$key=.*|$key='$bad'|"
    expect_fail_with "key $key has an invalid value" build "op-bad-$i"
    err=$(build "op-bad-$i" 2>&1 || true)
    ! grep -qF -- "'$bad'" <<<"$err" || fail "error message echoes the $key value '$bad'"
done <<'CASES'
OP_MCCMNC=2970
OP_MCCMNC=297021
OP_MCCMNC=29a02
OP_NAME=A very long operator name
OP_NAME=-Acme
OP_NAME=Acme$(id)
OP_CURRENCY=usd
OP_CURRENCY=USDX
OP_BALANCE_QUERY_NUMBER=14
OP_BALANCE_QUERY_NUMBER=14 66
OP_BALANCE_QUERY_TEXT=-h
OP_BALANCE_QUERY_TEXT=BAL;id
OP_BALANCE_REPLY_FROM=ACME!
OP_SHORT_CODES=4040,4041
OP_BALANCE_REPLY_PATTERN=Balance without the amount
OP_BALANCE_REPLY_PATTERN=Balance {amount} {amount}
OP_BALANCE_REPLY_PATTERN=Balance {amount} till {day}
OP_BALANCE_REPLY_PATTERN=Balance {amount} {year}
OP_BALANCE_REPLY_PATTERN=Balance {any} {amount}
OP_BALANCE_REPLY_PATTERN=Balance {any}.{amount}
OP_BALANCE_REPLY_PATTERN=Balance [0-9]*{amount}
CASES

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

# R14a: LINK_RESTART_AFTER_S is a key every profile must have, a whole number of seconds from 120 to
# 900 (D79); anything else stops the build naming the key and the range, and the error never shows
# the value. The default and a value in range land in the watchcat config as its period.
key=LINK_RESTART_AFTER_S
range="use a whole number from 120 to 900"
variant "no-$key" "/^$key=/d"
expect_fail_with "key $key is missing; copy it from generic.conf" build "no-$key"
variant "empty-$key" "s/^$key=.*/$key=''/"
expect_fail_with "key $key is empty" build "empty-$key"
i=0
# the edges (119, 901), zero, a leading zero, signs, a fraction, text, a unit, a space and
# fullwidth digits
for bad in 0 60 119 901 99999 0120 -120 +120 120.5 ten 120s '1 20' ' 120' '１２０'; do
    i=$((i + 1))
    variant "bad-$key-$i" "s|^$key=.*|$key='$bad'|"
    expect_fail_with "key $key has an invalid value; $range" build "bad-$key-$i"
    err=$(build "bad-$key-$i" 2>&1 || true)
    ! grep -qF -- "'$bad'" <<<"$err" || fail "error message echoes the $key value '$bad'"
done
for good in 120 121 300 600 899 900; do
    variant "good-$key-$good" "s|^$key=.*|$key='$good'|"
    build --render-only "good-$key-$good" "$SCRATCH/good-$key-$good" 2>/dev/null ||
        fail "$key '$good' was rejected"
    grep -qxF "	option period '$good'" "$SCRATCH/good-$key-$good/etc/config/watchcat" ||
        fail "$key '$good' is not the period of wwan_soft in etc/config/watchcat"
done
build --render-only generic "$SCRATCH/generic-link" 2>/dev/null || fail "the generic profile was rejected"
grep -qxF "	option period '120'" "$SCRATCH/generic-link/etc/config/watchcat" ||
    fail "the generic image does not restart wwan after 120 s"
# D79: the lower bound is two ping periods; the ping period is not a profile key, so it must stay 60
grep -qxF "	option pingperiod '60'" "$SCRATCH/generic-link/etc/config/watchcat" ||
    fail "pingperiod of wwan_soft is not 60: the range of $key (D79) no longer holds"
[ "$(grep -c 'option period' "$SCRATCH/generic-link/etc/config/watchcat")" = 1 ] ||
    fail "etc/config/watchcat has more than one period"
! grep -Eq '@[A-Z]' "$SCRATCH/generic-link/etc/config/watchcat" || fail "a placeholder is left in etc/config/watchcat"

# R3, R29c: LOG_LEVEL is a key every profile must have, exactly `info` or `debug`; anything else stops
# the build naming the key and the allowed values, and the error never shows the value. Both values
# land in the first-boot script as they are.
key=LOG_LEVEL
allowed="use info or debug"
variant "no-$key" "/^$key=/d"
expect_fail_with "key $key is missing; copy it from generic.conf" build "no-$key"
variant "empty-$key" "s/^$key=.*/$key=''/"
expect_fail_with "key $key is empty; $allowed" build "empty-$key"
i=0
for bad in DEBUG Debug INFO Info warn verbose trace 'info ' ' debug' 'debug,info' 0 1 true 'ｄｅｂｕｇ'; do
    i=$((i + 1))
    variant "bad-$key-$i" "s|^$key=.*|$key='$bad'|"
    expect_fail_with "key $key has an invalid value; $allowed" build "bad-$key-$i"
    err=$(build "bad-$key-$i" 2>&1 || true)
    ! grep -qF -- "'$bad'" <<<"$err" || fail "error message echoes the $key value '$bad'"
done
for good in info debug; do
    variant "good-$key-$good" "s|^$key=.*|$key='$good'|"
    build --render-only "good-$key-$good" "$SCRATCH/good-$key-$good" 2>/dev/null || fail "$key '$good' was rejected"
    grep -qxF "P_$key='$good'" "$SCRATCH/good-$key-$good/etc/uci-defaults/zz-lw-config" ||
        fail "$key '$good' not written verbatim"
done
build --render-only generic "$SCRATCH/generic-log" 2>/dev/null || fail "the generic profile was rejected"
grep -qxF "P_$key='info'" "$SCRATCH/generic-log/etc/uci-defaults/zz-lw-config" || fail "the generic image is not at the info level"

# R33b: ROOT_PASSWORD is a key every profile must have; 8 to 63 printable ASCII characters like
# WIFI_KEY; with ROOT_PASSWORD_HASH also set the build stops naming both keys; the clear text reaches
# neither the build output nor the overlay, only its $6$ hash does
variant no-rootpw '/^ROOT_PASSWORD=/d'
expect_fail_with "key ROOT_PASSWORD is missing; add the line ROOT_PASSWORD=''" build no-rootpw
FAKE_ROOT=fake-root-pw-q7x9
rootpw() { sed -e "s/^ROOT_PASSWORD=.*/ROOT_PASSWORD='$1'/" -e "s/^ROOT_PASSWORD_HASH=.*/ROOT_PASSWORD_HASH=''/" \
    "$P/fake-full.conf" >"$P/$2.conf"; }
i=0
for bad in short7c "$(printf 'x%.0s' {1..64})" 'ünïcode-pw-q7x9' 'tab	tab-pw-q7x9'; do
    i=$((i + 1))
    rootpw "$bad" "bad-rootpw-$i"
    expect_fail_with "key ROOT_PASSWORD has an invalid value" build "bad-rootpw-$i"
    err=$(build "bad-rootpw-$i" 2>&1 || true)
    ! grep -qF -- "$bad" <<<"$err" || fail "error message echoes the ROOT_PASSWORD value '$bad'"
done
variant both-root "s/^ROOT_PASSWORD=.*/ROOT_PASSWORD='$FAKE_ROOT'/"
expect_fail_with "keys ROOT_PASSWORD and ROOT_PASSWORD_HASH are both set" build both-root
err=$(build both-root 2>&1 || true)
! grep -qF -- "$FAKE_ROOT" <<<"$err" || fail "the both-set error echoes the ROOT_PASSWORD value"
for good in "$FAKE_ROOT" 12345678 'with space pw!' "$(printf 'y%.0s' {1..63})"; do
    rootpw "$good" good-rootpw
    out=$(build --render-only good-rootpw "$SCRATCH/good-rootpw" 2>&1) || fail "ROOT_PASSWORD '$good' was rejected"
    ! grep -qF -- "$good" <<<"$out" || fail "the build output shows the ROOT_PASSWORD value"
    assert_absent "$SCRATCH/good-rootpw" "$good"
    hash=$(sed -n "s/^P_ROOT_PASSWORD_HASH='\(.*\)'$/\1/p" "$SCRATCH/good-rootpw/etc/uci-defaults/zz-lw-config")
    [[ $hash == "\$6\$"* ]] || fail "ROOT_PASSWORD '$good' did not become a \$6\$ hash"
    [ "$(openssl passwd -6 -salt "$(cut -d'$' -f3 <<<"$hash")" "$good")" = "$hash" ] ||
        fail "the hash in the overlay does not match ROOT_PASSWORD '$good'"
    [ ! -e "$SCRATCH/good-rootpw-passwords.txt" ] || fail "a profile with both passwords got a card"
    rm -rf -- "$SCRATCH/good-rootpw"
done
# an unchanged rebuild keeps the password; the hash gets a new salt
rootpw "$FAKE_ROOT" rootpw-twice
build --render-only rootpw-twice "$SCRATCH/twice-1" 2>/dev/null
build --render-only rootpw-twice "$SCRATCH/twice-2" 2>/dev/null
h1=$(sed -n "s/^P_ROOT_PASSWORD_HASH='\(.*\)'$/\1/p" "$SCRATCH/twice-1/etc/uci-defaults/zz-lw-config")
h2=$(sed -n "s/^P_ROOT_PASSWORD_HASH='\(.*\)'$/\1/p" "$SCRATCH/twice-2/etc/uci-defaults/zz-lw-config")
[ "$(openssl passwd -6 -salt "$(cut -d'$' -f3 <<<"$h1")" "$FAKE_ROOT")" = "$h1" ] &&
    [ "$(openssl passwd -6 -salt "$(cut -d'$' -f3 <<<"$h2")" "$FAKE_ROOT")" = "$h2" ] ||
    fail "a rebuild does not keep the ROOT_PASSWORD"
# the card is written because the WiFi key is drawn; it lists the profile's root password and wins
# over an older card, and the drawn WiFi key comes back from the card
sed -e "s/^WIFI_KEY=.*/WIFI_KEY=''/" "$P/good-rootpw.conf" >"$P/card-rootpw.conf"
mkdir -p "$SCRATCH/cardimg"
printf 'ssid=old\nwifi=keep-this-wifi\nroot=old-root-from-card\n' >"$SCRATCH/cardimg/card-rootpw-passwords.txt"
LW_PROFILES=$P LW_IMAGE=$SCRATCH/cardimg "$FW/build.sh" --render-only card-rootpw "$SCRATCH/card-out" 2>/dev/null
grep -qxF "root=$(printf 'y%.0s' {1..63})" "$SCRATCH/card-out-passwords.txt" ||
    fail "the card does not list the profile's ROOT_PASSWORD"
grep -qxF "wifi=keep-this-wifi" "$SCRATCH/card-out-passwords.txt" || fail "the card's WiFi key was not reused"
! grep -q 'old-root-from-card' "$SCRATCH/card-out-passwords.txt" || fail "an older card won over ROOT_PASSWORD"
# the hash alone is still accepted and lands verbatim; both empty draws a password (R33)
hash_in=$(sed -n "s/^ROOT_PASSWORD_HASH='\(.*\)'$/\1/p" "$P/fake-full.conf")
build --render-only fake-full "$SCRATCH/hash-only" 2>/dev/null || fail "ROOT_PASSWORD_HASH alone was rejected"
grep -qxF "P_ROOT_PASSWORD_HASH='$hash_in'" "$SCRATCH/hash-only/etc/uci-defaults/zz-lw-config" ||
    fail "ROOT_PASSWORD_HASH was not written verbatim"
variant both-empty "s/^ROOT_PASSWORD_HASH=.*/ROOT_PASSWORD_HASH=''/"
build --render-only both-empty "$SCRATCH/both-empty" 2>/dev/null || fail "both root keys empty was rejected"
grep -qE '^root=.{8,}' "$SCRATCH/both-empty-passwords.txt" || fail "no root password was drawn"

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
    -e "s/^SSH_KEYS=.*/SSH_KEYS=''/" -e "s/^\(OP_[A-Z_]*\)=.*/\1=''/" \
    "$P/fake-full.conf" >"$P/blanks.conf"
build --render-only blanks "$SCRATCH/blanks" 2>/dev/null || fail "allowed empty values were rejected"
grep -qx "P_SMS_ADMINS=''" "$SCRATCH/blanks/etc/uci-defaults/zz-lw-config" ||
    fail "an empty SMS_ADMINS is not written as empty"
grep -qx "P_WWAN_PIN=''" "$SCRATCH/blanks/etc/uci-defaults/zz-lw-config" ||
    fail "an empty WWAN_PIN is not written as empty"
[ "$(ls "$SCRATCH/blanks/usr/share/lw/operators")" = 29702 ] ||
    fail "R47d: empty OP_ keys wrote a preset file"

# R3b: VERSION (MAJOR.MINOR.PATCH, optional -prerelease) is read by every build; a missing file or a
# malformed value stops the build naming VERSION, and a good one lands in /etc/lw-build (R7b)
vbuild() { LW_VERSION_FILE=$1 build "${@:2}"; }
expect_fail_with "VERSION is missing" vbuild "$SCRATCH/no-such-VERSION" generic
i=0
for bad in '' ' ' 1 1.2 1.2.3.4 v1.2.3 01.2.3 1.02.3 1.2.03 1.2.3- 1.2.3-rc_1 1.2.3-rc..1 1.2.3+build \
    ' 1.2.3' '1.2.3 ' '1.2.-3' 'x.y.z' '１.２.３' '1.2.3-ü' '1.2.3
1.2.4'; do
    i=$((i + 1))
    printf '%s\n' "$bad" >"$SCRATCH/bad-version-$i"
    expect_fail_with "VERSION is not MAJOR.MINOR.PATCH" vbuild "$SCRATCH/bad-version-$i" generic
done
: >"$SCRATCH/empty-version"
expect_fail_with "VERSION is not MAJOR.MINOR.PATCH" vbuild "$SCRATCH/empty-version" generic
i=0
for good in 0.1.0 1.2.3 10.20.30 0.0.0 1.0.0-rc.1 2.3.4-beta 1.0.0-0.3.7 1.0.0-x-y-z.1; do
    i=$((i + 1))
    printf '%s\n' "$good" >"$SCRATCH/good-version-$i"
    vbuild "$SCRATCH/good-version-$i" --render-only generic "$SCRATCH/good-version-out-$i" 2>/dev/null ||
        fail "VERSION '$good' was rejected"
    grep -qx "version=$good" "$SCRATCH/good-version-out-$i/etc/lw-build" ||
        fail "VERSION '$good' is not in etc/lw-build"
done
printf '0.9.9' >"$SCRATCH/no-newline-version"
vbuild "$SCRATCH/no-newline-version" --render-only generic "$SCRATCH/no-newline-out" 2>/dev/null ||
    fail "VERSION without a trailing newline was rejected"
grep -qx "version=0.9.9" "$SCRATCH/no-newline-out/etc/lw-build" || fail "VERSION without newline not in lw-build"

# R3c: an empty TIMEZONE takes the string of ZONENAME from the configurator's zone table; a zone the
# table lacks stops the build, a TIMEZONE of the profile is kept, and only an empty one needs the page
zz=etc/uci-defaults/zz-lw-config
variant tz-ny "s/^TIMEZONE=.*/TIMEZONE=''/; s|^ZONENAME=.*|ZONENAME='America/New_York'|"
build --render-only tz-ny "$SCRATCH/tz-ny-out" 2>/dev/null || fail "an empty TIMEZONE was refused"
grep -qx "P_TIMEZONE='EST5EDT,M3.2.0,M11.1.0'" "$SCRATCH/tz-ny-out/$zz" ||
    fail "an empty TIMEZONE did not take the string of ZONENAME"
variant tz-mars "s/^TIMEZONE=.*/TIMEZONE=''/; s|^ZONENAME=.*|ZONENAME='Mars/Olympus'|"
expect_fail_with "key TIMEZONE is empty and ZONENAME is not in the configurator's list" build tz-mars
variant tz-own "s/^TIMEZONE=.*/TIMEZONE='XYZ-3'/; s|^ZONENAME=.*|ZONENAME='Mars/Olympus'|"
LW_ZONES_PAGE=$SCRATCH/no-page.html build --render-only tz-own "$SCRATCH/tz-own-out" 2>/dev/null ||
    fail "a profile with its own TIMEZONE needed the configurator page"
grep -qx "P_TIMEZONE='XYZ-3'" "$SCRATCH/tz-own-out/$zz" || fail "the profile's TIMEZONE was replaced"
LW_ZONES_PAGE=$SCRATCH/no-page.html expect_fail_with "no zone list" build tz-ny

[ "$(listing "$I")" = "$before" ] || fail "a failed build changed image/: $(listing "$I")"
echo ok
