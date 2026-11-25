# R32a, D219: the root login shell writes its history to flash, so it survives a restart. The
# package's busybox-history-file.sh sets HISTFILE to /tmp; this file sorts after it and sets it back.
export HISTFILE=/root/.ash_history
