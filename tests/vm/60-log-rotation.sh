#!/usr/bin/env bash
# Persistent log with rotation (R29): syslog goes to /root/openwrt.log, which logread turns into
# openwrt.log.old at 1 MB (log_size 1024 KB), and both survive a reboot. The log is flooded with
# 6000 lines of about 200 bytes (1.2 MB) through logger.
# shellcheck disable=SC2016,SC2119 # guest scripts expand in the guest; helper args are optional
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

LIMIT=1048576
LINES=6000

vm_init
vm_start
must "guest boots" vm_wait_ready
gcheck "logread writes /root/openwrt.log with a 1024 KB limit" \
    'ps w | grep "[l]ogread -f -F"; ps w | grep -q "[l]ogread -f -F /root/openwrt.log .*-S 1024"'

must "flood syslog with $LINES lines" vm_sh \
    "pad=\$(printf '%0180d' 0); i=0
     while [ \$i -lt $LINES ]; do echo \"lwvm-flood \$i \$pad\"; i=\$((i + 1)); done |
         logger -t lwvm-flood" 300
check "last flood line reaches the persistent log within 60 s" \
    vm_wait_for "grep -q 'lwvm-flood $((LINES - 1)) ' /root/openwrt.log" 60
gcheck "rotated: openwrt.log.old is 1 MB, openwrt.log below 1 MB" \
    "ls -l /root/openwrt.log*
     old=\$(wc -c </root/openwrt.log.old); cur=\$(wc -c </root/openwrt.log)
     [ \$old -ge $LIMIT ] && [ \$old -le $((LIMIT + 4096)) ] && [ \$cur -le $((LIMIT + 4096)) ]"
gnote 'ls -l /root/openwrt.log*'
gcheck "no flood line lost between the two files" \
    "n=\$(cat /root/openwrt.log.old /root/openwrt.log | grep -c 'lwvm-flood: lwvm-flood ')
     echo \"\$n of $LINES\"; [ \$n -eq $LINES ]"

must "reboot" vm_reboot
gcheck "both files survive the reboot and the new boot appends to openwrt.log" \
    "[ -s /root/openwrt.log.old ] && grep -q 'lwvm-flood $((LINES - 1)) ' /root/openwrt.log &&
     tail -n 5 /root/openwrt.log | grep -qv lwvm-flood"

finish
