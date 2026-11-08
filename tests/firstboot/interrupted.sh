# SPEC R8a: power lost in the middle of zz-lw-config. Changes not yet committed are gone (they sit
# in /tmp/.uci), boot never removed the script, so the next boot runs it whole; the result must
# equal an uninterrupted first boot. Cut after every `uci commit` and after the shadow write.
# shellcheck source=tests/firstboot/fb-lib
. /fw/tests/firstboot/fb-lib
fb_prepare fake-full
UD=/etc/uci-defaults/zz-lw-config
tar -cf /tmp/etc-before.tar -C / etc

restore() {
    rm -rf /etc/config /etc/rc.d /etc/lw-firstboot.pending /tmp/.uci
    tar -xf /tmp/etc-before.tar -C /
}

fb_uci_defaults
reference=$(fb_state)

cuts=$(grep -n -e '^uci commit' -e '^    uci commit' -e "sed -i" "$UD" | cut -d: -f1)
[ -n "$cuts" ] || lw_fail "no cut points found"
for cut in $cuts; do
    restore
    head -n "$cut" "$UD" >/tmp/partial
    # a cut inside an if block is closed so the partial script parses, as an aborted run would
    sh -n /tmp/partial 2>/dev/null || echo 'fi' >>/tmp/partial
    fb_uci_defaults /tmp/partial
    rm -rf /tmp/.uci
    fb_uci_defaults
    lw_expect_eq "$(fb_state)" "$reference" "state after a run cut at line $cut"
done
echo ok
