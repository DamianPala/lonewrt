# R51: the text of the Wi-Fi QR code, WIFI:T:WPA;S:<name>;P:<password>;; (T:nopass and no P for an
# open network, H:true for a hidden name). The characters \ ; , : " in the name and the password each
# get a backslash in front, as the format of the phone cameras demands; nothing else is touched.
# tests/hostnet/qr-roundtrip.sh reads the same strings back with a real decoder.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
lw_setup
# shellcheck source=src/files/usr/lib/lw/common.sh
. /usr/lib/lw/common.sh
# shellcheck source=src/files/usr/lib/lw/notify.sh
. /usr/lib/lw/notify.sh
# shellcheck source=src/files/usr/lib/lw/devices.sh
. /usr/lib/lw/devices.sh

# case SSID KEY HIDDEN EXPECTED
case_() {
    lw_expect_eq "$(nt_qr_wifi "$1" "$2" "$3")" "$4" "QR text for '$1' / '$2'"
}

case_ HomeWifi secret-pass-1 '' 'WIFI:T:WPA;S:HomeWifi;P:secret-pass-1;;'
case_ Home-Guest blue-lamp-4521 0 'WIFI:T:WPA;S:Home-Guest;P:blue-lamp-4521;;'
# a hidden network
case_ Home-Guest blue-lamp-4521 1 'WIFI:T:WPA;S:Home-Guest;P:blue-lamp-4521;H:true;;'
# an open network: nopass, no P field, also with H
case_ Guest '' '' 'WIFI:T:nopass;S:Guest;;'
case_ Guest '' 1 'WIFI:T:nopass;S:Guest;H:true;;'
# each of the five special characters alone, in the name and in the password
case_ 'a\b' 'c\d' '' 'WIFI:T:WPA;S:a\\b;P:c\\d;;'
case_ 'a;b' 'c;d' '' 'WIFI:T:WPA;S:a\;b;P:c\;d;;'
case_ 'a,b' 'c,d' '' 'WIFI:T:WPA;S:a\,b;P:c\,d;;'
case_ 'a:b' 'c:d' '' 'WIFI:T:WPA;S:a\:b;P:c\:d;;'
case_ 'a"b' 'c"d' '' 'WIFI:T:WPA;S:a\"b;P:c\"d;;'
# all at once, and at the ends of the text
case_ '\;,:"' '"\:,;' '' 'WIFI:T:WPA;S:\\\;\,\:\";P:\"\\\:\,\;;;'
case_ ';start' 'end\' '' 'WIFI:T:WPA;S:\;start;P:end\\;;'
# a backslash is not doubled twice: the text "\\" is two backslashes, each escaped
case_ '\\' 'x' '' 'WIFI:T:WPA;S:\\\\;P:x;;'
# what is not special stays: spaces (also at the ends), quotes of other kinds, & < > % and UTF-8
case_ " Karo's WiFi " 'p&ss=w0rd%41 +x<i>' '' "WIFI:T:WPA;S: Karo's WiFi ;P:p&ss=w0rd%41 +x<i>;;"
case_ 'Zażółć' 'hasło-żółw-77' '' 'WIFI:T:WPA;S:Zażółć;P:hasło-żółw-77;;'
# only digits, a password that looks like a field, a name that looks like the whole string
case_ 12345678 87654321 '' 'WIFI:T:WPA;S:12345678;P:87654321;;'
case_ 'S:x' 'P:y' '' 'WIFI:T:WPA;S:S\:x;P:P\:y;;'
case_ 'WIFI:T:WPA;S:a;P:b;;' k '' 'WIFI:T:WPA;S:WIFI\:T\:WPA\;S\:a\;P\:b\;\;;P:k;;'
# the longest name and password of the standard (32 and 63 characters) stay one line
long=$(printf 'x%.0s' $(seq 1 63))
case_ abcdefghijklmnopqrstuvwxyz012345 "$long" '' "WIFI:T:WPA;S:abcdefghijklmnopqrstuvwxyz012345;P:$long;;"
echo ok
