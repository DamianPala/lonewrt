# shellcheck shell=sh disable=SC3043  # BusyBox ash supports local

QMI_DIR=/fw/tests/qmi
PATH=$QMI_DIR/stubs:$PATH
export QMI_STATE PATH

qmi_fixture() {
    # Each test has a fresh rootfs. qmi.sh discovers wwan0 through the USB control node.
    QMI_STATE=$(mktemp -d /tmp/qmi.XXXXXX)
    NOTIFY=$QMI_STATE/notify_proto.jsonl
    DYNAMIC=$QMI_STATE/add_dynamic.jsonl
    mkdir "$QMI_STATE/clients" "$QMI_STATE/calls"
    mkdir -p \
        /sys/class/usbmisc/cdc-wdm0/device/net/wwan0 /sys/class/net/wwan0/qmi
    printf 'N\n' >/sys/class/net/wwan0/qmi/raw_ip
    cp "$QMI_DIR/scenarios/$1" "$QMI_STATE/scenario"
    printf '17\n' >"$QMI_STATE/next-cid"
    printf 'raw-ip\n' >"$QMI_STATE/data-format"
    printf '{"up":false,"data":{}}\n' >"$QMI_STATE/status.json"
    touch "$NOTIFY" "$DYNAMIC" "$QMI_STATE/uqmi.jsonl"
}

qmi_run() {
    local rc=0 config
    # device, modes and timeout mirror zz-lw-config; APN is synthetic and credentials are absent.
    # netifd passes protocol options, so proto and multipath are outside this JSON.
    config=$(printf '{%s"timeout":30,"pdptype":"%s"%s}' \
        '"device":"/dev/cdc-wdm0","apn":"internet.example","modes":"lte",' "$2" "${3:+,$3}")
    timeout 10 "$QMI_DIR/handler" "$1" "$config" || rc=$?
    if [ -s "$QMI_STATE/unexpected" ]; then
        cat "$QMI_STATE/unexpected" >&2
        lw_fail 'unexpected modem or ubus command'
    fi
    return "$rc"
}

qmi_json_lines() {
    awk 'BEGIN { printf "[" } NR > 1 { printf "," } { printf "%s", $0 } END { print "]" }' "$1" |
        jsonfilter -e "$2" || :
}

qmi_arg_count() {
    grep -cF "\"$1\"" "$QMI_STATE/uqmi.jsonl" || :
}

qmi_child() {
    qmi_json_lines "$DYNAMIC" "@[@.name=\"$1\"].$2"
}

qmi_notify() {
    qmi_json_lines "$NOTIFY" "@[@.action=$1]$2"
}
