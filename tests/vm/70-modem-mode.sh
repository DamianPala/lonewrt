#!/usr/bin/env bash
# Modem state on every boot through the real sms_tool, flock and timeout (R11, R11a, R11c): a modem
# left in auto mode with B7 and SMS store SM gets LTE-only and store ME, bands only when the
# profile names them; on the next boot, with everything in place, only the SMS store command goes.
# shellcheck disable=SC2016,SC2119 # guest scripts expand in the guest; helper args are optional
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

mask_of() {
    local m=0 b
    for b in ${1//,/ }; do m=$((m | (1 << (b - 1)))); done
    printf '%x' "$m"
}

vm_init
modem_start '{"zsnt": [0, 0, 0], "lte_mask": "880800c5", "cpms_mem": ["SM", "SM", "SR"]}'
vm_start
must "guest boots" vm_wait_ready
bands=$(vm_sh 'uci -q get lonewrt.modem.bands' || true)
want_mask=880800c5
[ -z "$bands" ] || want_mask=$(mask_of "$bands")
note "lonewrt.modem.bands='$bands', expected band mask $want_mask"

check "lw-modem-mode reports 'modem OK' within 300 s (R11)" \
    vm_wait_for 'logread -e lw-modem-mode | grep -q "modem OK"' 300
gnote 'logread -e lw-modem-mode'
check "modem in LTE-only mode 6,0,0" test "$(modem_get zsnt)" = "[6, 0, 0]"
check "SMS store ME for read, write and receive" test "$(modem_get cpms_mem)" = '["ME", "ME", "ME"]'
check "band mask $want_mask (profile bands '$bands', R11c)" \
    test "$(modem_get lte_mask)" = "\"$want_mask\""
if [ -z "$bands" ]; then
    check "no band command without bands in the profile (R11c)" \
        bash -c "! grep -q 'AT+ZNLOCKBAND=' '$RUN/modem/at.log'"
fi

seen=$(wc -l <"$RUN/modem/at.log")
must "reboot" vm_reboot
check "'modem OK' again after the reboot" \
    vm_wait_for 'logread -e lw-modem-mode | grep -q "modem OK"' 300
tail -n +"$((seen + 1))" "$RUN/modem/at.log" >"$RUN/modem/at-second-boot.log"
note "AT commands on the second boot: $(cut -f2 "$RUN/modem/at-second-boot.log" | sort -u |
    tr '\n' ' ')"
check "second boot: no mode or band change (R11a)" \
    bash -c "! grep -qE 'AT\\+(ZSNT|ZNLOCKBAND)=' '$RUN/modem/at-second-boot.log'"
check "second boot: the SMS store command still goes (R11a)" \
    grep -q 'AT+CPMS=' "$RUN/modem/at-second-boot.log"
gcheck "second boot: no 'setting' entries from lw-modem-mode" \
    '! logread -e lw-modem-mode | grep -q setting'

finish
