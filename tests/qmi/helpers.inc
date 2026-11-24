# shellcheck shell=sh disable=SC3043  # BusyBox ash supports local

QMI_DIR=/fw/tests/qmi
PATH=$QMI_DIR/stubs:$PATH
export QMI_STATE PATH LW_UPTIME_FILE LW_CLAT_DIR

# qmi_fixture SCENARIO: a fresh modem. Profile 1 starts as the image's forced IPv4 leaves it (IPv4
# and the test APN), the SIM is ready, the clock is the file the handler reads (R73h).
qmi_fixture() {
    # Each test has a fresh rootfs. qmi.sh discovers wwan0 through the USB control node.
    QMI_STATE=$(mktemp -d /tmp/qmi.XXXXXX)
    LW_UPTIME_FILE=$QMI_STATE/uptime
    LW_CLAT_DIR=$QMI_STATE/clat
    NOTIFY=$QMI_STATE/notify_proto.jsonl
    DYNAMIC=$QMI_STATE/add_dynamic.jsonl
    mkdir "$QMI_STATE/clients" "$QMI_STATE/calls"
    mkdir -p \
        /sys/class/usbmisc/cdc-wdm0/device/net/wwan0 /sys/class/net/wwan0/qmi "$LW_TEST"
    printf 'N\n' >/sys/class/net/wwan0/qmi/raw_ip
    cp "$QMI_DIR/scenarios/$1" "$QMI_STATE/scenario"
    printf '17\n' >"$QMI_STATE/next-cid"
    printf 'raw-ip\n' >"$QMI_STATE/data-format"
    printf '{"up":false,"data":{}}\n' >"$QMI_STATE/status.json"
    printf '1000.00 1000.00\n' >"$LW_UPTIME_FILE"
    printf '8900000000000000001\n' >"$QMI_STATE/iccid"
    : >"$LW_TEST/syslog"
    : >"$LW_TEST/syslog.prio"
    rm -f /etc/lw-wwan-ptype
    qmi_profile internet.example ipv4
    touch "$NOTIFY" "$DYNAMIC" "$QMI_STATE/uqmi.jsonl"
}

# qmi_profile APN TYPE [off]: profile 1 of the modem (off: the APN is disabled)
qmi_profile() {
    printf '%s\n' "$1" >"$QMI_STATE/profile.apn"
    printf '%s\n' "$2" >"$QMI_STATE/profile.pdp"
    rm -f "$QMI_STATE/profile.off"
    [ "${3:-}" != off ] || : >"$QMI_STATE/profile.off"
}

# qmi_fault MATCH ACTION [SKIP [TIMES]]: the stand-in fails calls whose arguments hold MATCH
# (actions in stubs/uqmi)
qmi_fault() {
    printf '%s|%s|%s|%s\n' "$1" "$2" "${3:-0}" "${4:-0}" >>"$QMI_STATE/fault"
}

# qmi_debug: the debug log level (R29c)
qmi_debug() {
    touch /etc/config/lonewrt
    uci set lonewrt.log=log
    uci set lonewrt.log.level=debug
    uci commit lonewrt
}

# qmi_clock: the stand-in's clock in whole seconds
qmi_clock() {
    cut -d. -f1 "$LW_UPTIME_FILE"
}

# qmi_run ACTION PDPTYPE [EXTRA_JSON]: one call of the handler as netifd makes it. Device, modes
# and timeout mirror zz-lw-config; the APN is synthetic (QMI_APN, empty allowed) and credentials are
# absent. dhcp and dhcpv6 are omitted, as in the image, unless EXTRA_JSON sets them. netifd passes
# protocol options, so proto and multipath are outside this JSON.
qmi_run() {
    local rc=0 config
    config=$(printf '{%s"timeout":30,"pdptype":"%s"%s}' \
        "\"device\":\"/dev/cdc-wdm0\",\"apn\":\"${QMI_APN-internet.example}\",\"modes\":\"lte\"," \
        "$2" "${3:+,$3}")
    timeout 10 "$QMI_DIR/handler" "$1" "$config" || rc=$?
    if [ -s "$QMI_STATE/unexpected" ]; then
        cat "$QMI_STATE/unexpected" >&2
        lw_fail 'unexpected modem or ubus command'
    fi
    return "$rc"
}

# qmi_ifdown: what netifd does at the end of a session: the teardown, with the data it published
qmi_ifdown() {
    qmi_run teardown "$1" || lw_fail 'teardown failed'
}

qmi_json_lines() {
    awk 'BEGIN { printf "[" } NR > 1 { printf "," } { printf "%s", $0 } END { print "]" }' "$1" |
        jsonfilter -e "$2" || :
}

qmi_arg_count() {
    grep -cF "\"$1\"" "$QMI_STATE/uqmi.jsonl" || :
}

# qmi_calls: every uqmi call, one line each, without the options every call has
qmi_calls() {
    qmi_calls_raw | sed -e 's|^\(-s \)\{0,1\}-d /dev/cdc-wdm0 -t [0-9]* ||'
}

# qmi_calls_raw: the same with every option
qmi_calls_raw() {
    sed -e 's/^{ *"argv": *\[ *//' -e 's/ *\] *}$//' -e 's/", *"/ /g' -e 's/"//g' \
        -e 's|\\/|/|g' "$QMI_STATE/uqmi.jsonl"
}

# qmi_calls_from PATTERN: the calls from the first one that holds PATTERN on (the preamble of a start
# is stock)
qmi_calls_from() {
    qmi_calls | sed -n "/$1/,\$p"
}

# qmi_count PATTERN: how many calls hold PATTERN
qmi_count() {
    qmi_calls | grep -c -e "$1" || :
}

# qmi_first_line PATTERN: the number of the first call that holds PATTERN (0: none)
qmi_first_line() {
    qmi_calls | grep -n -e "$1" | head -n 1 | cut -d: -f1 | grep . || echo 0
}

# qmi_syslog: the lines the handler wrote with its tag, priority first
qmi_syslog() {
    grep ' lw-qmi: ' "$LW_TEST/syslog.prio" || :
}

qmi_child() {
    qmi_json_lines "$DYNAMIC" "@[@.name=\"$1\"].$2"
}

qmi_notify() {
    qmi_json_lines "$NOTIFY" "@[@.action=$1]$2"
}

# qmi_failed_starts: the failures the handler reported to netifd (error notifications)
qmi_failed_starts() {
    qmi_json_lines "$NOTIFY" '@[@.action=3].error[*]'
}

# qmi_modem_clean: no client and no call left in the modem
qmi_modem_clean() {
    lw_expect_eq "$(ls "$QMI_STATE/clients")" '' "${1:-}: clients left"
    lw_expect_eq "$(ls "$QMI_STATE/calls")" '' "${1:-}: calls left"
}
