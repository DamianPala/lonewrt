#!/usr/bin/env bash
# cron really runs the image's jobs (R7 table, cron row) without logging every start (R29a):
# lw-siglog adds a line to /tmp/lw-signal.log (R28), wwan-recover and lw-sms-clean start.
# The guest clock is set back to 75 s before each job's first run of a day. busybox crond starts
# nothing for a clock that went backwards, and it notices the jump only when its current sleep
# (up to 60 s) ends, so 75 s leaves it time to resync before the job's minute; every job then
# starts from its own schedule line, with crond untouched.
# shellcheck disable=SC2016,SC2119 # guest scripts expand in the guest; helper args are optional
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

vm_init
vm_start
must "guest boots" vm_wait_ready
gcheck "crond runs with log level 9, jobs do not log their start (R29a)" \
    'ps w | grep "[c]rond"; ps w | grep -q "[c]rond .*-l 9"'

# first_run FIELD DEFAULT: the first value a cron minute/hour field matches (*/5 -> 0, 2-59/5 -> 2)
first_run() {
    case $1 in
        '*' | '*/'*) echo "$2" ;;
        *) echo "${1%%[!0-9]*}" ;;
    esac
}

# clock_before_job JOB DAY: set the guest clock to 75 s before JOB's first run time on DAY
clock_before_job() {
    local line minute hour at
    line=$(vm_sh "grep ' /usr/sbin/$1\$' /etc/crontabs/root | head -n1")
    minute=$(first_run "$(echo "$line" | cut -d' ' -f1)" 0)
    hour=$(first_run "$(echo "$line" | cut -d' ' -f2)" 0)
    at=$(TZ=UTC date -d "$2 $hour:$minute:00 75 seconds ago" '+%Y-%m-%d %H:%M:%S')
    note "$1: '$line', guest clock set to $at"
    vm_sh "date -s '$at' >/dev/null"
}

# Phase 1, cron as the image sets it up: lw-siglog leaves its line, crond logs nothing about it
lines_before=$(vm_sh 'cat /tmp/lw-signal.log 2>/dev/null | wc -l')
clock_before_job lw-siglog 2026-01-03
check "lw-siglog runs from cron: new line in /tmp/lw-signal.log within 150 s" \
    vm_wait_for "[ \$(cat /tmp/lw-signal.log 2>/dev/null | wc -l) -gt $lines_before ]" 150
gnote 'tail -n1 /tmp/lw-signal.log'
fields='zsnt net pb s1 rsrp rsrq sinr rssi pci loss rtt wg_age'
gcheck "the line has the R28 fields in order" \
    "re='^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9:]{8}'
     for f in $fields; do re=\"\$re \$f=[^ ]*\"; done
     tail -n1 /tmp/lw-signal.log | grep -qE \"\$re\\\$\""
gcheck "no crond job-start lines in the log (R29a)" '! logread | grep -q "crond.*cmd "'

# Phase 2, test-only: crond at log level 8 shows which job it started
must "switch crond to log level 8 (test only)" vm_sh \
    'uci set system.@system[0].cronloglevel=8 && uci commit system && /etc/init.d/cron restart &&
     sleep 1 && ps w | grep -q "[c]rond .*-l 8"'
clock_before_job wwan-recover 2026-01-02
check "cron starts wwan-recover within 150 s" \
    vm_wait_for 'logread | grep -q "crond.*cmd /usr/sbin/wwan-recover"' 150
clock_before_job lw-sms-clean 2026-01-01
check "cron starts lw-sms-clean within 150 s" \
    vm_wait_for 'logread | grep -q "crond.*cmd /usr/sbin/lw-sms-clean"' 150
gnote 'logread | grep -E "crond.*cmd |wwan-recover|lw-sms-clean|lw-siglog" | tail -n 8'

finish
