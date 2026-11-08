#!/usr/bin/env bash
# Factory reset with `firstboot -y && reboot`, the software side of the reset button: a change made
# on the router survives a plain reboot (R9) and is gone after the reset, which brings back exactly
# the image's configuration (R7) with a fresh log and a new lw-firstboot entry (R7b).
# Then a power cut 10 s after the reset boot has finished: the overlay must be marked ready
# (fstools /overlay/.fs_state -> 2, set by init's `done`), so the next start is a normal boot and
# keeps what was written, not another first boot on a wiped overlay (R7, R8a).
# shellcheck disable=SC2016,SC2119 # guest scripts expand in the guest; helper args are optional
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

vm_init
vm_start
must "guest boots" vm_wait_ready
uci_export_normalized >"$RUN/uci-export-flash.txt"
gnote 'echo "fs_state after the first boot from flash: $(readlink /overlay/.fs_state)"'

must "owner changes the hostname, leaves a file and a log line" vm_sh \
    'uci set system.@system[0].hostname=lwvm-changed && uci commit system &&
     echo owner >/root/lwvm-owner-file && logger -t lwvm-test "before reset"'
must "plain reboot" vm_reboot
gcheck "change survives a plain reboot (R9)" \
    '[ "$(uci get system.@system[0].hostname)" = lwvm-changed ] && [ -f /root/lwvm-owner-file ]'

must "firstboot -y && reboot" vm_sh '(sleep 1; firstboot -y && reboot) >/dev/null 2>&1 &'
must "guest boots after the reset" vm_wait_ready
gcheck "owner's file is gone" '[ ! -e /root/lwvm-owner-file ]'
uci_export_normalized >"$RUN/uci-export-reset.txt"
check "uci export equals the one right after flash" \
    diff "$RUN/uci-export-flash.txt" "$RUN/uci-export-reset.txt"
gcheck "persistent log starts over: no line from before the reset" \
    '[ -f /root/openwrt.log ] && ! grep -q "lwvm-test" /root/openwrt.log'
gcheck "lw-firstboot entry again after the reset (R7b)" \
    'i=0; until grep -q "lw-firstboot" /root/openwrt.log; do
         i=$((i + 1)); [ $i -lt 30 ] || exit 1; sleep 1; done'

# init's `done` (START=95) runs before lw-vm-ready (99), so the reset boot is past it here
gnote 'echo "fs_state after the reset boot: $(readlink /overlay/.fs_state)"'
gcheck "overlay marked ready after the reset boot (.fs_state -> 2)" \
    '[ "$(readlink /overlay/.fs_state)" = 2 ]'
must "marker in /root, sync, wait 10 s" vm_sh \
    'echo after-reset >/root/lwvm-after-reset && sync && sleep 10' 30
must "power cut" vm_py kill --run "$RUN"
vm_start
must "guest boots after the power cut" vm_wait_ready
gnote 'echo "fs_state after the power cut: $(readlink /overlay/.fs_state)"'
gcheck "marker survived the power cut (overlay not wiped)" '[ -f /root/lwvm-after-reset ]'
gcheck "no second lw-firstboot entry (not a first boot again)" \
    'n=$(grep -c "lw-firstboot" /root/openwrt.log); echo "lw-firstboot entries: $n"; [ "$n" = 1 ]'

finish
