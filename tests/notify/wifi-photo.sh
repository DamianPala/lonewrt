# R51, D90: /wifi answers with a photo, the QR code of the first network, and an HTML caption with
# the names and passwords that a guest can use outside the group (no command, no "for guests"). The
# QR maker is a stand-in that records the text it was given (the string of the code is also tested in
# qr-string.sh and read back by a real decoder in tests/hostnet/qr-roundtrip.sh). The upload is
# parsed by the fake Bot API from the bytes (tests/notify/stubs/uclient-fetch). With no picture, or
# a refused one, the answer is the text of R43, so /wifi always answers; a network failure follows
# the rule of every answer to a command: it is lost, not queued.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup 7.50
qr_on
passes 2

ap() {
    uci set wireless.default_radio"$1"=wifi-iface
    uci set wireless.default_radio"$1".device=radio"$1"
    uci set wireless.default_radio"$1".mode=ap
    uci set wireless.default_radio"$1".network=lan
    uci set wireless.default_radio"$1".ssid="$2"
    uci set wireless.default_radio"$1".encryption=psk2
    uci set wireless.default_radio"$1".key="$3"
}
wireless() {
    : >/etc/config/wireless
    uci set wireless.radio0=wifi-device
    uci set wireless.radio0.band=2g
    uci set wireless.radio1=wifi-device
    uci set wireless.radio1.band=5g
    ap 0 "$1" "$2"
    ap 1 "$3" "$4"
    uci commit wireless
}
# ask [TEXT]: the command, the photo it got; the last message number is in $m
ask() {
    tg_push "$TG_CHAT" "${1:-/wifi}"
    pass
    m=$(sent)
}
flash_state() {
    find /etc /root -type f -exec ls -li {} + | sort
    find /etc /root -type f -exec md5sum {} + | sort
}
# photo_ok N CAPTION QR: message N is a photo with this caption and the picture the QR maker made for
# this code (the last one), uploaded as wifi.jpg
photo_ok() {
    lw_expect_eq "$(cat "$G/sent/$1.caption")" "$2" "caption of message $1"
    lw_expect_eq "$(mode_of "$1")" HTML "parse_mode of message $1"
    lw_expect_eq "$(cat "$G/sent/$1.photoname")" wifi.jpg "file name"
    lw_expect_eq "$(cat "$G/sent/$1.phototype")" image/jpeg "photo type"
    lw_expect_eq "$(cat "$G/sent/$1.chat")" "$TG_CHAT" "chat"
    lw_expect_eq "$(qr_text "$(qr_n)")" "$3" "text of the QR code"
    cmp "$G/sent/$1.photo" "$T/qr/$(qr_n).jpg" || lw_fail "the photo is not the QR picture, byte for byte"
}
# pgm_ok: the picture the last code got from cjpeg is the code of qrencode's text, square, every module
# a square of PX pixels (8 to 12), dark modules 0 and light ones 255, about 400 to 600 pixels wide
pgm_ok() {
    _pn=$(qr_n)
    _pm=$(cat "$T/qr/$_pn.modules")
    read -r _pw _ph <"$T/qr/$_pn.dim"
    lw_expect_eq "$_ph" "$_pw" "the picture is square"
    [ $((_pw % _pm)) = 0 ] || lw_fail "width $_pw is not a whole number of the $_pm modules"
    _ppx=$((_pw / _pm))
    [ "$_ppx" -ge 8 ] && [ "$_ppx" -le 12 ] || lw_fail "$_ppx pixels per module"
    [ "$_pw" -ge 390 ] && [ "$_pw" -le 600 ] || lw_fail "the picture is $_pw pixels wide"
    lw_expect_eq "$(awk -v px="$_ppx" -v w="$_pw" '
        FNR == NR { row[FNR - 1] = $0; next }
        { for (i = 1; i <= NF; i++) {
            k++
            if (k <= 4) continue
            p = k - 5
            ch = substr(row[int(int(p / w) / px)], 2 * int((p % w) / px) + 1, 1)
            if ($i != (ch == "#" ? 0 : 255)) bad++
        } }
        END { print bad + 0, k }' "$T/qr/$_pn.ascii" "$T/qr/last.pgm")" "0 $((_pw * _pw + 4))" \
        "pixels that differ from the modules"
}
# no_leftovers: no picture, request body or error file stays behind in RAM
no_leftovers() {
    lw_expect_eq "$(find /tmp/lw-notify -name 'qr.*' -o -name 'photo.*' -o -name 'body.*' -o -name 'err.*')" "" \
        "files left in RAM"
}

# one network on both bands: one photo, nothing else
wireless HomeWifi secret-pass-1 HomeWifi secret-pass-1
before=$(flash_state)
: >"$T/syslog"
ask
lw_expect_eq "$m" 1 "messages after /wifi"
photo_ok 1 "📶 <b>Wi-Fi</b>
Name: <code>HomeWifi</code>
Password: <code>secret-pass-1</code>

Scan the code with the phone camera to join." 'WIFI:T:WPA;S:HomeWifi;P:secret-pass-1;;'
case $(cat "$T/qr/1.args") in
    '-t ASCII -m 4') ;;
    *) lw_fail "options of qrencode: $(cat "$T/qr/1.args")" ;;
esac
case $(cat "$T/qr/1.cjpeg") in
    '-quality 90 -grayscale -outfile /tmp/lw-notify/qr.'*'.jpg') ;;
    *) lw_fail "options of cjpeg: $(cat "$T/qr/1.cjpeg")" ;;
esac
pgm_ok
lw_expect_eq "$(cat "$T/qr/1.dim")" "444 444" "37 modules at 12 pixels"
# the caption stands on its own, as text: no bot command, no "guests", no slash
cap=$(plain_of "$(cat "$G/sent/1.caption")")
for w in / guest command tap; do
    ! printf '%s' "$cap" | grep -qi -- "$w" || lw_fail "caption has '$w'"
done
lw_expect_eq "$(grep -c . "$T/syslog")" 0 "syslog after a photo"
lw_expect_eq "$(flash_state)" "$before" "flash after a photo"
no_leftovers
# the request body held the password: 0600 like every file of the bot (R34i)
lw_expect_eq "$(sort -u "$G/body-modes")" "-rw-------" "mode of the request bodies"
# the token and the password are in no file the test can read, but the caption (the password itself)
for f in "$G"/sent/*.text; do lw_expect_no_grep "$f" TESTtokq7x9; done
lw_expect_no_grep "$T/syslog" secret-pass-1
lw_expect_no_grep "$T/syslog" TESTtokq7x9

# the button gives the same
ask '📶 Wi-Fi'
lw_expect_eq "$m" 2 "messages after the button"
photo_ok 2 "$(cat "$G/sent/1.caption")" 'WIFI:T:WPA;S:HomeWifi;P:secret-pass-1;;'

# other names: the QR is for the first network, the caption keeps the others in the order of /wifi
wireless HomeWifi secret-pass-1 HomeWifi-5G secret-pass-1
ask
photo_ok "$m" "📶 <b>Wi-Fi</b>
Name: <code>HomeWifi</code>
Password: <code>secret-pass-1</code>

Name: <code>HomeWifi-5G</code>
Password: same password

Scan the code with the phone camera to join the first network." 'WIFI:T:WPA;S:HomeWifi;P:secret-pass-1;;'
wireless HomeWifi secret-pass-1 HomeWifi other-pass-22
ask
photo_ok "$m" "📶 <b>Wi-Fi</b>
Name: <code>HomeWifi</code>
Password: <code>secret-pass-1</code>

Name: <code>HomeWifi</code>
Password: <code>other-pass-22</code>

Scan the code with the phone camera to join the first network." 'WIFI:T:WPA;S:HomeWifi;P:secret-pass-1;;'

# the first network is the first that is switched on
uci set wireless.radio0.disabled=1
uci commit wireless
ask
photo_ok "$m" "📶 <b>Wi-Fi</b>
Name: <code>HomeWifi</code>
Password: <code>other-pass-22</code>

Scan the code with the phone camera to join." 'WIFI:T:WPA;S:HomeWifi;P:other-pass-22;;'
uci delete wireless.radio0.disabled
uci commit wireless

# an open network: nopass, "Password: none"; a protected first and an open second keep the first's QR
uci -q batch <<'UCI'
set wireless.default_radio0.ssid=Guest
set wireless.default_radio0.encryption=none
delete wireless.default_radio0.key
set wireless.default_radio1.ssid=Guest
set wireless.default_radio1.encryption=none
delete wireless.default_radio1.key
commit wireless
UCI
ask
photo_ok "$m" "📶 <b>Wi-Fi</b>
Name: <code>Guest</code>
Password: none

Scan the code with the phone camera to join." 'WIFI:T:nopass;S:Guest;;'
wireless HomeWifi secret-pass-1 HomeWifi-open x
uci set wireless.default_radio1.encryption=none
uci delete wireless.default_radio1.key
uci commit wireless
ask
photo_ok "$m" "📶 <b>Wi-Fi</b>
Name: <code>HomeWifi</code>
Password: <code>secret-pass-1</code>

Name: <code>HomeWifi-open</code>
Password: none

Scan the code with the phone camera to join the first network." 'WIFI:T:WPA;S:HomeWifi;P:secret-pass-1;;'
# an open network that still has a key option left behind: still nopass
uci set wireless.default_radio0.encryption=none
uci set wireless.default_radio0.key=left-behind-key
uci commit wireless
ask
lw_expect_eq "$(qr_text "$(qr_n)")" 'WIFI:T:nopass;S:HomeWifi;;' "open network with a key left behind"

# a hidden network: H:true
wireless Home-Guest blue-lamp-4521 Home-Guest blue-lamp-4521
uci set wireless.default_radio0.hidden=1
uci commit wireless
ask
lw_expect_eq "$(qr_text "$(qr_n)")" 'WIFI:T:WPA;S:Home-Guest;P:blue-lamp-4521;H:true;;' "hidden network"
uci delete wireless.default_radio0.hidden
uci commit wireless

# hostile name and password: the caption is HTML-escaped (R37g, the fake Bot API refuses broken
# markup), the QR text is escaped for the QR format, and neither is read as the other
wireless '<b>&"a;b,c:d\e' 'p&ss;w,o:r"d\<i>' '<b>&"a;b,c:d\e' 'p&ss;w,o:r"d\<i>'
ask
photo_ok "$m" '📶 <b>Wi-Fi</b>
Name: <code>&lt;b&gt;&amp;"a;b,c:d\e</code>
Password: <code>p&amp;ss;w,o:r"d\&lt;i&gt;</code>

Scan the code with the phone camera to join.' 'WIFI:T:WPA;S:<b>&\"a\;b\,c\:d\\e;P:p&ss\;w\,o\:r\"d\\<i>;;'
wireless 'Zażółć' 'hasło-żółw-77' 'Zażółć' 'hasło-żółw-77'
ask
lw_expect_eq "$(qr_text "$(qr_n)")" 'WIFI:T:WPA;S:Zażółć;P:hasło-żółw-77;;' "UTF-8 in the QR text"
lw_expect_eq "$(sed -n 2p "$G/sent/$m.caption")" 'Name: <code>Zażółć</code>' "UTF-8 in the caption"

# the size of the picture follows the size of the code: 12 pixels for a short text, fewer for a long
# one, and always about 400 to 600 pixels; the pixels are the modules of qrencode's text
wireless Home-Guest blue-lamp-4521 Home-Guest blue-lamp-4521
ask
pgm_ok
lw_expect_eq "$(cat "$T/qr/$(qr_n).dim")" "444 444" "a short text: 37 modules, 12 pixels"
long=$(printf 'k%.0s' $(seq 1 63))
wireless abcdefghijklmnopqrstuvwxyz012345 "$long" x y
ask
pgm_ok
lw_expect_eq "$(cat "$T/qr/$(qr_n).dim")" "490 490" "the longest plain text: 49 modules, 10 pixels"
# the longest text there can be, every character of a name and a key escaped: 8 pixels
semi32=$(printf ';%.0s' $(seq 1 32))
semi63=$(printf ';%.0s' $(seq 1 63))
wireless "$semi32" "$semi63" x y
ask
pgm_ok
lw_expect_eq "$(cat "$T/qr/$(qr_n).dim")" "488 488" "an escaped text of 208 bytes: 61 modules, 8 pixels"

# --- no photo: the text of R43 answers, and the log says why (no name, no password, no token) ---
wireless HomeWifi secret-pass-1 HomeWifi secret-pass-1
text="📶 <b>Wi-Fi</b>
Name: <code>HomeWifi</code>
Password: <code>secret-pass-1</code>"
# fallback_ok LOG: the last message is the text, one new log line says LOG
fallback_ok() {
    lw_expect_eq "$(last_text)" "$text" "$1: the text answers"
    [ ! -f "$G/sent/$m.photo" ] || lw_fail "$1: the text came as a photo"
    lw_expect_eq "$(sed 's/^[0-9]* //' "$T/syslog")" "$2" "$1: log"
    lw_expect_no_grep "$T/syslog" secret-pass-1
    lw_expect_no_grep "$T/syslog" HomeWifi
    lw_expect_no_grep "$T/syslog" TESTtokq7x9
    no_leftovers
}
nopic="lw-notify: Wi-Fi photo not sent: no QR image could be made, sent as text"
n0=$(sent)
for mode in fail empty ragged; do
    echo "$mode" >"$T/qr/mode"
    : >"$T/syslog"
    ask
    lw_expect_eq "$m" $((n0 + 1)) "one message with qrencode in mode $mode"
    fallback_ok "qrencode $mode" "$nopic"
    n0=$m
done
rm -f "$T/qr/mode"
for mode in fail empty missing; do
    echo "$mode" >"$T/qr/jpeg_mode"
    : >"$T/syslog"
    ask
    lw_expect_eq "$m" $((n0 + 1)) "one message with cjpeg in mode $mode"
    fallback_ok "cjpeg $mode" "$nopic"
    n0=$m
done
rm -f "$T/qr/jpeg_mode"
# the packages are not in the image, one after the other
: >"$T/qr/no-cjpeg"
: >"$T/syslog"
ask
lw_expect_eq "$m" $((n0 + 1)) "one message without cjpeg"
fallback_ok "no cjpeg" "$nopic"
n0=$m
rm -f "$T/qr/no-cjpeg"
qr_off
: >"$T/syslog"
ask
lw_expect_eq "$m" $((n0 + 1)) "one message without qrencode"
fallback_ok "no qrencode" "$nopic"
n0=$m
qr_on
# Telegram refuses the photo with HTTP 400: one text, the refusal is not a lost link
echo 400 >"$G/reject_photo"
: >"$T/syslog"
rej=$(rejected_n)
ask
lw_expect_eq "$m" $((n0 + 1)) "one message after a refused photo"
fallback_ok "HTTP 400" "lw-notify: Wi-Fi photo not sent: Telegram refused it (HTTP 400), sent as text"
lw_expect_eq "$(rejected_n)" $((rej + 1)) "one refusal"
lw_expect_eq "$([ -f /tmp/lw-notify/down ] && echo down || echo up)" up "link state after a 400"
rm -f "$G/reject_photo"
n0=$m
# a caption over the limit (many networks): the text, which Telegram takes up to 4096 characters
: >/etc/config/wireless
uci set wireless.radio0=wifi-device
i=0
big=
while [ "$i" -lt 14 ]; do
    uci set wireless.n$i=wifi-iface
    uci set wireless.n$i.device=radio0
    uci set wireless.n$i.mode=ap
    uci set wireless.n$i.ssid="Network-number-$i-with-a-long-name"
    uci set wireless.n$i.encryption=psk2
    uci set wireless.n$i.key="a-longer-key-for-network-$i-0123456789"
    i=$((i + 1))
done
uci commit wireless
: >"$T/syslog"
ask
lw_expect_eq "$m" $((n0 + 1)) "one message for a long caption"
[ ! -f "$G/sent/$m.photo" ] || lw_fail "a caption over the limit went out as a photo"
lw_expect_eq "$(last_text | head -n 1)" "📶 <b>Wi-Fi</b>" "the text for a long caption"
lw_expect_eq "$(last_text | grep -c '^Name:')" 14 "all 14 networks in the text"
lw_expect_eq "$(sed 's/^[0-9]* //' "$T/syslog")" \
    "lw-notify: Wi-Fi photo not sent: the caption is too long, sent as text" "log for a long caption"
n0=$m
# no network switched on: the text says so, no picture is made
wireless HomeWifi secret-pass-1 HomeWifi secret-pass-1
uci set wireless.default_radio0.disabled=1
uci set wireless.default_radio1.disabled=1
uci commit wireless
q0=$(qr_n)
ask
lw_expect_eq "$(last_text)" "📶 No Wi-Fi network is switched on." "everything off"
lw_expect_eq "$(qr_n)" "$q0" "a picture for no network"
n0=$m

# --- the network fails, or Telegram answers 500: the answer is lost, not queued, and not repeated
# as a text; one /wifi makes one picture
wireless HomeWifi secret-pass-1 HomeWifi secret-pass-1
for fail in net 500 429; do
    echo "$fail" >"$G/photo_fail"
    q0=$(qr_n)
    ask
    lw_expect_eq "$m" "$n0" "messages with sendPhoto failing ($fail)"
    lw_expect_eq "$(qr_n)" $((q0 + 1)) "the picture is made once ($fail)"
    no_leftovers
    lw_expect_eq "$(find /etc/lw-notify/queue -type f 2>/dev/null | wc -l | tr -d ' ')" 0 "queue after a lost answer"
    for _ in 1 2 3; do pass; done
    lw_expect_eq "$(sent)" "$n0" "the lost answer does not come back ($fail)"
done
rm -f "$G/photo_fail"
ask
photo_ok "$m" "$text

Scan the code with the phone camera to join." 'WIFI:T:WPA;S:HomeWifi;P:secret-pass-1;;'
n0=$m

# other chats get nothing and cost no picture
q0=$(qr_n)
tg_push "$TG_OTHER" /wifi
pass
lw_expect_eq "$(sent)" "$n0" "answer to a foreign chat"
lw_expect_eq "$(qr_n)" "$q0" "picture for a foreign chat"
no_orphans
echo ok
