# R50, R50a, D87 to D89: a device gets a name from the chat. /devices carries the button "Name a
# device"; its tap sends a list of the devices of the month (those without a name first, at most 12,
# a Cancel, short names two to a row); a tap on a device sends a force_reply prompt; the reply from the
# configured chat is the name: no control characters, spaces collapsed, at most 24 characters (not
# bytes), "-" removes it. The name replaces the DHCP name in /devices and in the list; the one file on
# flash holds "<mac><tab><name>" lines (at most 64, the oldest go), is written only when something
# changes, and outlives a restart. The list and the prompt stand for 10 min, a reply to a prompt that
# is gone says so, a name is shown escaped (R37g), a reply from another chat is ignored.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup 7.50
passes 2

GB=1000000000
NAMES=/etc/lw-notify/devnames
NOKB='{"inline_keyboard":[]}'
ASK_GONE='This request expired, tap ✏️ Name a device again.'
POPUP='This button expired, tap ✏️ Name a device again.'
TAB=$(printf '\t')
# the devices: Alice's phone and one without a DHCP name on Wi-Fi, the PC on the cable, a laptop and
# another device without a name that are away
A=aa:bb:cc:00:00:01
U=aa:bb:cc:00:3c:5d
C=aa:bb:cc:00:00:03
L=11:22:33:44:55:66
X=aa:bb:cc:00:b1:0f

wifi_client hostapd.phy0-ap0 2437 $A $U
arp_set $A $U $C
lease_set "$A 192.168.1.20 Alice-iPhone" "$U 192.168.1.21 *" "$C 192.168.1.22 cable-pc" \
    "$L 192.168.1.23 old-laptop"
nlbw_set "$A $((12 * GB)) 400000000" "$U 130350000 50000000" "$C 800000000 100000000" \
    "$L $((20 * GB)) 4900000000" "$X 3000000 2000000"

# files: every file of the writable state, with its inode and checksum
files() { find /etc /root -type f -exec ls -li {} + | sort; find /etc /root -type f -exec md5sum {} + | sort; }
# lapse S: S seconds pass on both clocks, without a service pass
lapse() { lw_uptime_add "$1"; wall_add "$1"; }
# rows_of N: the labels of the buttons of message N, one row per line, joined by "|"
rows_of() {
    _ro=0
    while _rl=$(markup_of "$1" | jsonfilter -e "@.inline_keyboard[$_ro][*].text" 2>/dev/null) &&
        [ -n "$_rl" ]; do
        printf '%s|\n' "$(printf '%s\n' "$_rl" | tr '\n' '|' | sed 's/|$//')"
        _ro=$((_ro + 1))
    done
}
# devices: /devices from the chat; D is its message
devices() {
    tg_push "$TG_CHAT" /devices
    pass
    D=$(sent)
}
# picker [MSG]: the tap on "Name a device" of message MSG (default D); P is the list it sends
picker() {
    tg_tap "$TG_CHAT" "${1:-$D}" dn:new
    pass
    P=$(sent)
}
# pick N: the tap on the Nth button of the list P; PR is the prompt it sends
pick() {
    tg_tap "$TG_CHAT" "$P" "$(button_data "$P" "$1")"
    pass
    PR=$(sent)
}
# pick_mac MAC: the same for the button of MAC
pick_mac() {
    _pk=$(markup_of "$P" | jsonfilter -e '@.inline_keyboard[*][*].callback_data' |
        grep -nx "dn:$(printf '%s' "$1" | tr -d ':')" | cut -d: -f1)
    [ -n "$_pk" ] || lw_fail "no button for $1 in $(rows_of "$P")"
    pick "$_pk"
}
# reply TEXT [PROMPT]: the reply to the prompt (default PR); CF is the message the bot sent for it
reply() {
    tg_reply "$TG_CHAT" "$1" "${2:-$PR}"
    pass
    CF=$(sent)
}
# name MAC TEXT: the whole flow for one device
name() {
    devices
    picker
    pick_mac "$1"
    reply "$2"
}
stored() { sed -n "s/^$1$TAB//p" "$NAMES"; }

# --- /devices carries the button; its text is the one of R44
devices
lw_expect_eq "$(markup_of "$D")" '{"inline_keyboard":[[{"text":"✏️ Name a device","callback_data":"dn:new"}]]}' \
    "button under /devices"
lw_expect_eq "$(last_text)" "📱 <b>Devices</b> · 38 GB this month (since 1 Nov)

<b>Connected now (3)</b>
• Alice-iPhone · 12.4 GB
• cable-pc · 0.9 GB
• Unknown device (…3c:5d) · 0.2 GB

<b>Earlier this month (2)</b>
• old-laptop · 24.9 GB
• Unknown device (…b1:0f) · &lt;0.1 GB" "/devices"
before=$(files)

# --- the list: unnamed first (connected before away), then the rest as /devices has them, Cancel last,
# short names two to a row; every callback_data fits Telegram's 64 bytes
picker
lw_expect_eq "$(last_text)" "✏️ <b>Which device do you want to name?</b>" "the list"
lw_expect_eq "$(answers)" 1 "answers to the tap"
lw_expect_eq "$(answer_alert 1)" "" "no pop-up for a good tap"
lw_expect_eq "$(rows_of "$P")" "Unknown device (…3c:5d)|
Unknown device (…b1:0f)|
Alice-iPhone|cable-pc|
old-laptop|Cancel|" "rows of the list"
lw_expect_eq "$(button_data "$P" 1)" dn:aabbcc003c5d "data of the first device"
lw_expect_eq "$(button_data "$P" 2)" dn:aabbcc00b10f "data of the second device"
lw_expect_eq "$(button_data "$P" 6)" dn:no "data of Cancel"
_i=1
while [ "$_i" -le 6 ]; do
    [ "$(button_data "$P" "$_i" | wc -c)" -le 64 ] || lw_fail "callback data $_i is longer than 64 bytes"
    _i=$((_i + 1))
done
lw_expect_eq "$(mode_of "$P")" HTML "parse_mode of the list"
lw_expect_eq "$(files)" "$before" "flash after the list"
# a tap on a device of the list: the list becomes "Naming ...", the prompt asks for a reply
lw_expect_eq "$(edits)" 0 "edits before the tap on a device"
LIST1=$(button_data "$P" 2)
pick 1
lw_expect_eq "$(edits)" 1 "edits after the tap on a device"
lw_expect_eq "$(edit_msgid 1)" "$P" "edited message"
lw_expect_eq "$(edit_text 1)" "✏️ Naming <b>Unknown device (…3c:5d)</b>" "text of the list after the tap"
lw_expect_eq "$(edit_markup 1)" "$NOKB" "buttons of the list after the tap"
lw_expect_eq "$(last_text)" "✏️ Send the new name for <b>Unknown device (…3c:5d)</b> as a reply to this message.
Up to 24 characters. Send <code>-</code> to remove a name." "the prompt"
lw_expect_eq "$(markup_of "$PR" | jsonfilter -e '@.force_reply')" true "force_reply"
[ -n "$(markup_of "$PR" | jsonfilter -e '@.input_field_placeholder')" ] || lw_fail "no placeholder"
lw_expect_eq "$(mode_of "$PR")" HTML "parse_mode of the prompt"
lw_expect_eq "$(files)" "$before" "flash after the prompt"
lw_expect_eq "$(sent)" "$PR" "messages after the tap on a device"
# a second tap on the same list: pop-up, nothing else (the list is used up)
tg_tap "$TG_CHAT" "$P" "$LIST1"
pass
lw_expect_eq "$(answer_alert "$(answers)")" true "pop-up for a button of a used list"
lw_expect_eq "$(answer_text "$(answers)")" "$POPUP" "pop-up text"
lw_expect_eq "$(sent)" "$PR" "messages after a tap on a used list"
lw_expect_eq "$(edits)" 1 "edits after a tap on a used list"
# a tap from another chat is ignored like its messages (R37)
n=$(answers)
tg_tap "$TG_OTHER" "$P" "$LIST1" Mallory
pass
lw_expect_eq "$(answers)" "$n" "answers to a foreign tap"

# --- what is not a name: a reply from another chat, a command, a keyboard press, a reply to another message
tg_reply "$TG_OTHER" "Mallory" "$PR"
pass
lw_expect_eq "$(sent)" "$PR" "messages after a reply from another chat"
lw_expect_eq "$(files)" "$before" "flash after a reply from another chat"
tg_reply "$TG_CHAT" /status "$PR"
pass
case $(last_text) in *"Internet"*) ;; *) lw_fail "/status as a reply gave: $(last_text)" ;; esac
tg_reply "$TG_CHAT" "📱 Devices" "$PR"
pass
case $(last_text) in "📱 <b>Devices</b>"*) ;; *) lw_fail "a keyboard press as a reply gave: $(last_text)" ;; esac
lw_expect_eq "$(files)" "$before" "flash after a command as a reply"
S=$(sent)
tg_reply "$TG_CHAT" "just talking" "$D"
pass
lw_expect_eq "$(sent)" "$S" "answers to a reply to /devices"

# --- the name: the confirmation, the file, /devices, the list
reply "Kate's iPhone"
lw_expect_eq "$(last_text)" "✅ <b>Unknown device (…3c:5d)</b> is now called <b>Kate's iPhone</b>." "confirmation"
lw_expect_eq "$(mode_of "$CF")" HTML "parse_mode of the confirmation"
lw_expect_eq "$(cat "$NAMES")" "$U${TAB}Kate's iPhone" "the file"
lw_expect_eq "$(find /etc /root -name '*tmp*' | wc -l | tr -d ' ')" 0 "temp files left on flash"
devices
case $(last_text) in
    *"• Kate's iPhone · 0.2 GB"*) ;;
    *) lw_fail "/devices lacks the name: $(last_text)" ;;
esac
# a second reply to the same prompt: it is used up
reply "Another" "$PR"
lw_expect_eq "$(last_text)" "$ASK_GONE" "second reply to a used prompt"
lw_expect_eq "$(cat "$NAMES")" "$U${TAB}Kate's iPhone" "the file after a second reply"
picker
lw_expect_eq "$(rows_of "$P")" "Unknown device (…b1:0f)|
Alice-iPhone|cable-pc|
Kate's iPhone|old-laptop|
Cancel|" "rows of the list after a name"

# --- a DHCP name is renamed and the old name is in the confirmation; the same name again writes nothing
name $A Alice
lw_expect_eq "$(last_text)" "✅ <b>Alice-iPhone</b> is now called <b>Alice</b>." "rename of a DHCP name"
lw_expect_eq "$(stored $A)" Alice "stored name of the DHCP device"
state=$(files)
name $A Alice
lw_expect_eq "$(last_text)" "✅ <b>Alice</b> is now called <b>Alice</b>." "same name again"
lw_expect_eq "$(files)" "$state" "flash after the same name"

# --- "-" removes a name of ours, the DHCP name is back; a device without a name says so
name $A -
lw_expect_eq "$(last_text)" "✅ Name removed: <b>Alice</b>." "removal"
lw_expect_eq "$(stored $A)" "" "the name is out of the file"
devices
case $(last_text) in *"• Alice-iPhone · 12.4 GB"*) ;; *) lw_fail "DHCP name not back: $(last_text)" ;; esac
name $X -
lw_expect_eq "$(last_text)" "ℹ️ <b>Unknown device (…b1:0f)</b> has no name of its own, nothing to remove." \
    "removal without a name"
lw_expect_eq "$(cat "$NAMES")" "$U${TAB}Kate's iPhone" "the file after the removals"
name $U -
lw_expect_eq "$(last_text)" "✅ Name removed: <b>Kate's iPhone</b>." "removal of the last name"
[ ! -e "$NAMES" ] || lw_fail "the file stays with no name in it"

# --- the text of a name: escaped, cut, cleaned
name $U '<b>&'
lw_expect_eq "$(last_text)" "✅ <b>Unknown device (…3c:5d)</b> is now called <b>&lt;b&gt;&amp;</b>." "hostile name"
devices
case $(last_text) in *"• &lt;b&gt;&amp; · 0.2 GB"*) ;; *) lw_fail "hostile name in /devices: $(last_text)" ;; esac
picker
lw_expect_eq "$(markup_of "$P" | jsonfilter -e '@.inline_keyboard[2][0].text')" "<b>&" \
    "hostile name on a button (plain text)"
expect_all_html
# a time marker in a name is only text (and the cut comes after the change)
name $A 'x@@TL:2026-11-07 11:20@@'
lw_expect_eq "$(stored $A)" 'x@ @TL:2026-11-07 11:20@' "time marker in a name"
case $(last_text) in *"<b>x@ @TL:2026-11-07 11:20@</b>."*) ;; *) lw_fail "marker shown: $(last_text)" ;; esac
# 30 ASCII characters: the first 24
name $U abcdefghijklmnopqrstuvwxyz0123
lw_expect_eq "$(stored $U)" abcdefghijklmnopqrstuvwx "cut at 24 characters"
# 30 two-byte and 30 four-byte characters: 24 of them, whole
cut2=
cut4=
all2=
all4=
_i=0
while [ "$_i" -lt 30 ]; do
    [ "$_i" -ge 24 ] || { cut2=${cut2}ż; cut4=${cut4}😀; }
    all2=${all2}ż
    all4=${all4}😀
    _i=$((_i + 1))
done
name $U "$all2"
lw_expect_eq "$(stored $U)" "$cut2" "cut of two-byte characters"
lw_expect_eq "$(stored $U | wc -c | tr -d ' ')" 49 "bytes of 24 two-byte characters and the new line"
name $U "$all4"
lw_expect_eq "$(stored $U)" "$cut4" "cut of four-byte characters"
lw_expect_eq "$(stored $U | wc -c | tr -d ' ')" 97 "bytes of 24 four-byte characters and the new line"
# exactly 24 characters stay as they are; a cut that ends in a space loses the space
name $U "$cut2"
lw_expect_eq "$(stored $U)" "$cut2" "24 characters"
name $U 'abcdefghijklmnopqrstuvw xyz'
lw_expect_eq "$(stored $U)" abcdefghijklmnopqrstuvw "cut at a space"
# control characters and line breaks are dropped, spaces collapse, the ends are trimmed
name $U '  A\u0001B\nC   D \t E  '
lw_expect_eq "$(stored $U)" "ABC D E" "cleaned name"
# the C1 range is control too (U+0085 is the two bytes C2 85); other characters of C2 stay
name $U "a$(printf '\302\205')b$(printf '\302\240')c"
lw_expect_eq "$(stored $U)" "ab$(printf '\302\240')c" "C1 control dropped"
# a reply is read to about 400 bytes, and that cut does not split a character either
long=a
_i=0
while [ "$_i" -lt 380 ]; do long="$long " && _i=$((_i + 1)); done
name $U "${long}😀😀😀😀😀"
lw_expect_eq "$(stored $U)" "a 😀😀😀😀😀" "a long reply read to a whole character"
# nothing left: an error, no change, the prompt stays open for another try
before=$(files)
devices
picker
pick_mac $U
reply '\n\t \u0001'
case $(last_text) in "⚠️ That name is empty."*) ;; *) lw_fail "empty name: $(last_text)" ;; esac
lw_expect_eq "$(files)" "$before" "flash after an empty name"
reply "Back again"
lw_expect_eq "$(stored $U)" "Back again" "name after an empty one"

# --- Cancel and the ten minutes
devices
picker
D1=$(button_data "$P" 1)
tg_tap "$TG_CHAT" "$P" dn:no
pass
lw_expect_eq "$(edit_text "$(edits)")" "✏️ Naming cancelled." "Cancel: text"
lw_expect_eq "$(edit_markup "$(edits)")" "$NOKB" "Cancel: buttons"
lw_expect_eq "$(sent)" "$P" "messages after Cancel"
n=$(edits)
tg_tap "$TG_CHAT" "$P" "$D1"
pass
lw_expect_eq "$(answer_text "$(answers)")" "$POPUP" "a tap on a cancelled list"
lw_expect_eq "$(edits)" "$n" "edits after a tap on a cancelled list"
# a list is good at 599 s (the pass of the tap adds one) and no longer at 601 s
picker
lapse 598
pick_mac $U
lw_expect_eq "$(edit_markup "$(edits)")" "$NOKB" "list at 599 s"
lapse 598
reply "Late but good"
lw_expect_eq "$(stored $U)" "Late but good" "prompt at 599 s"
picker
lapse 600
n=$(sent)
e=$(edits)
tg_tap "$TG_CHAT" "$P" "$(button_data "$P" 1)"
pass
lw_expect_eq "$(answer_alert "$(answers)")" true "pop-up for a list at 601 s"
lw_expect_eq "$(sent)" "$n" "messages after a tap on a list at 601 s"
lw_expect_eq "$(edits)" "$e" "edits after a tap on a list at 601 s"
# a prompt is gone after 601 s
picker
pick 1
lapse 600
before=$(files)
reply "Too late"
lw_expect_eq "$(last_text)" "$ASK_GONE" "reply to a prompt at 601 s"
lw_expect_eq "$(files)" "$before" "flash after a reply to an old prompt"
# a newer list replaces the older: the old one is closed and its buttons give the pop-up
devices
picker
OLD=$P
OLDDATA=$(button_data "$P" 1)
picker
lw_expect_eq "$(shown "$OLD")" "✏️ Naming cancelled." "the older list"
tg_tap "$TG_CHAT" "$OLD" "$OLDDATA"
pass
lw_expect_eq "$(answer_text "$(answers)")" "$POPUP" "a tap on the older list"
# the button under an old /devices opens a new list at any time
lapse 5000
picker "$D"
lw_expect_eq "$(last_text)" "✏️ <b>Which device do you want to name?</b>" "list from an old /devices"
# two prompts at once: each reply goes to its own device
picker
pick_mac $U
PR1=$PR
picker
pick_mac $X
PR2=$PR
reply "Second" "$PR2"
reply "First" "$PR1"
lw_expect_eq "$(stored $U)" First "name of the first prompt"
lw_expect_eq "$(stored $X)" Second "name of the second prompt"

# --- the file: one line per name, "mac<tab>name"; at most 64, the oldest go; a restart keeps it
rm -f "$NAMES"
_i=1
while [ "$_i" -le 64 ]; do
    printf 'cc:00:00:00:00:%02x\tseed %s\n' "$_i" "$_i" >>"$NAMES"
    _i=$((_i + 1))
done
name $U "Newest"
lw_expect_eq "$(wc -l <"$NAMES" | tr -d ' ')" 64 "entries after the 65th"
lw_expect_eq "$(head -n 1 "$NAMES")" "cc:00:00:00:00:02${TAB}seed 2" "the oldest entry went"
lw_expect_eq "$(tail -n 1 "$NAMES")" "$U${TAB}Newest" "the newest is the last"
# a name changed moves to the end, without a second line
name $U "Newest, renamed"
lw_expect_eq "$(wc -l <"$NAMES" | tr -d ' ')" 64 "entries after a rename"
lw_expect_eq "$(grep -c "^$U" "$NAMES")" 1 "lines of one device"
lw_expect_eq "$(tail -n 1 "$NAMES")" "$U${TAB}Newest, renamed" "the renamed is the last"
# a flash that cannot be written: said so, nothing stored, no temp file; the prompt stays open
mv_fail devnames
before=$(files)
devices
picker
pick_mac $A
reply "Cannot save"
case $(last_text) in "⚠️ Could not save the name"*) ;; *) lw_fail "full flash: $(last_text)" ;; esac
lw_expect_eq "$(files)" "$before" "flash after a failed write"
mv_ok
reply "Can save now"
lw_expect_eq "$(stored $A)" "Can save now" "name after a failed write"
# a restart: the names stay on flash and show in /devices, the open list and prompt are forgotten
picker
pick_mac $X
picker
LISTDATA=$(button_data "$P" 1)
reboot_sim
ntp_on
wall_set '2026-11-07 12:20'
nlbw_set "$A $((12 * GB)) 400000000" "$U 130350000 50000000" "$C 800000000 100000000" \
    "$L $((20 * GB)) 4900000000" "$X 3000000 2000000"
passes 2
lw_expect_eq "$(stored $A)" "Can save now" "name after a restart"
devices
case $(last_text) in *"• Can save now · 12.4 GB"*) ;; *) lw_fail "name lost over a restart: $(last_text)" ;; esac
tg_tap "$TG_CHAT" "$P" "$LISTDATA"
pass
lw_expect_eq "$(answer_text "$(answers)")" "$POPUP" "a tap on a list from before the restart"
reply "After restart" "$PR"
lw_expect_eq "$(last_text)" "$ASK_GONE" "a reply to a prompt from before the restart"
lw_expect_eq "$(stored $X)" "" "no name from a forgotten prompt"

# --- 15 devices: the list shows 12, the one without a name first; a DHCP name with a quote and a
# backslash goes to its button as valid JSON
rm -f "$NAMES"
: >"$T/leases"
: >/tmp/nlbw-mem
macs=
_i=1
while [ "$_i" -le 15 ]; do
    _m=$(printf 'bb:00:00:00:00:%02x' "$_i")
    macs="$macs $_m"
    case $_i in
        15) ;;
        14) printf '1794000000 %s 192.168.1.49 q"uo\\te 01:%s\n' "$_m" "$_m" >>"$T/leases" ;;
        *) printf '1794000000 %s 192.168.1.%s host-%s 01:%s\n' "$_m" "$((30 + _i))" "$_i" "$_m" >>"$T/leases" ;;
    esac
    # the one without a name has the least data
    if [ "$_i" = 15 ]; then echo "$_m 1000 0" >>/tmp/nlbw-mem; else echo "$_m $((_i * GB)) 0" >>/tmp/nlbw-mem; fi
    _i=$((_i + 1))
done
# shellcheck disable=SC2086  # one argument per MAC
wifi_client hostapd.phy0-ap0 2437 $macs
arp_set
devices
picker
lw_expect_eq "$(markup_of "$P" | jsonfilter -e '@.inline_keyboard[*][*].text' | wc -l | tr -d ' ')" 13 \
    "buttons: 12 devices and Cancel"
lw_expect_eq "$(rows_of "$P" | head -n 1)" "Unknown device (…00:0f)|" "the device without a name is first"
lw_expect_eq "$(rows_of "$P" | sed -n 2p)" 'q"uo\te|host-13|' "next two share a row"
lw_expect_eq "$(rows_of "$P" | tail -n 1)" "host-4|Cancel|" "last row"
lw_expect_eq "$(markup_of "$P" | jsonfilter -e '@.inline_keyboard[*][*].callback_data' | sed -n 2p)" \
    dn:bb000000000e "data of the second device"
lw_expect_eq "$(rows_of "$P" | grep -c 'host-[123]|')" 0 "devices beyond the twelfth"

# --- nothing of this wrote to syslog or left anything on flash but the names
lw_expect_eq "$(cat "$T/syslog")" "" "syslog"
expect_all_html
echo ok
