#!/usr/bin/env bash
# First boot with no AT port at all (QEMU gets no second UART): LAN and SSH come up without waiting
# for the modem (R8), and lw-modem-mode logs that the port never appeared (R11b).
# shellcheck disable=SC2016,SC2119 # guest scripts expand in the guest; helper args are optional
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

vm_init
vm_start --no-modem
t=$SECONDS
must "guest boots to the end of its init scripts" vm_wait_ready
note "boot took $((SECONDS - t)) s without a modem"
# a boot that waited for the port (120 s, R11b) would still end, so its length is the R8 check
check "boot does not wait for the modem: all init scripts done within 60 s (R8)" \
    test "$((SECONDS - t))" -lt 60

check "no AT port in the guest" vm_sh '[ ! -e /dev/ttyUSB2 ]'
gcheck "LAN br-lan has $LAN_IP within 30 s" \
    "i=0; until ip -4 addr show br-lan | grep -q 'inet $LAN_IP/'; do
         i=\$((i + 1)); [ \$i -lt 30 ] || exit 1; sleep 1; done"
check "SSH answers on LAN" vm_py banner --run "$RUN" --timeout 30
check "first-boot configuration applied anyway" vm_sh '[ -z "$(ls /etc/uci-defaults)" ]'

# R11b: the port must appear within 120 s, otherwise one syslog entry and nothing more
check "lw-modem-mode logs the missing AT port within 200 s (R11b)" \
    vm_wait_for 'logread -e lw-modem-mode | grep -v "modem OK" | grep -qiE "ttyUSB2|port"' 200
gnote 'logread -e lw-modem-mode'
gcheck "no 'modem OK' without a modem" '! logread -e lw-modem-mode | grep -q "modem OK"'
check "SSH still answers after the modem timeout" vm_py banner --run "$RUN" --timeout 10

finish
