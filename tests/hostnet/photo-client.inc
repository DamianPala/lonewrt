# shellcheck shell=sh disable=SC2034,SC1091
# The client side of tests/hostnet/photo-upload.sh (not a test itself): run in the OpenWrt rootfs by
# busybox sh with the network of the host. nt_photo of the image's notify.sh sends each request of
# /expect/N/ with the real uclient-fetch of the rootfs to the server on 127.0.0.1. Prints
# "rc=<n> msgid=<id>" per request, then the files that stay in RAM afterwards (there must be none).
# Environment: PORT, TOKEN, and /expect (the expect folder of photo-server.py, read-only).
umask 077
LW_TG_API=http://127.0.0.1:$PORT
export LW_TG_API
. /fw/src/files/usr/lib/lw/common.sh
. /fw/src/files/usr/lib/lw/notify.sh
. /fw/src/files/usr/lib/lw/multipart.sh
NT_RUN=/tmp/lw-notify-proof
NT_DIR=$NT_RUN/flash
NT_TOKEN=$TOKEN
NT_HTTP_LIMIT=10
mkdir -p "$NT_RUN"
n=1
while [ -d "/expect/$n" ]; do
    NT_CHAT=$(cat "/expect/$n/chat_id")
    rc=0
    nt_photo "/expect/$n/photo" "$(cat "/expect/$n/photo.type")" \
        "$(cat "/expect/$n/caption")" || rc=$?
    echo "rc=$rc msgid=$NT_MSGID"
    n=$((n + 1))
done
find "$NT_RUN" -type f
