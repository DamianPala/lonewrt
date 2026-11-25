# R32a, D219: a root login shell keeps its history in /root/.ash_history on flash. The package's
# profile.d file sets HISTFILE to /tmp; the image's file sorts after it and sets it back. A
# non-interactive shell reads no profile and gets no HISTFILE. The keep list names the file, so a
# flash that keeps settings keeps the history.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
lw_setup

lw_expect_grep /etc/profile.d/busybox-history-file.sh 'HISTFILE=/tmp/'

# the router's login shell (dropbear starts it with -l): /etc/profile sources profile.d in name order
login=$(printf 'echo "H=$HISTFILE"\nexit\n' | /bin/ash -l -i 2>&1 | sed -n 's/.*H=//p')
lw_expect_eq "$login" "/root/.ash_history" "HISTFILE of a login shell"

# a command over ssh (dropbear runs ash -c) reads no profile
plain=$(/bin/ash -c 'echo "H=[$HISTFILE]"')
lw_expect_eq "$plain" "H=[]" "HISTFILE of a non-interactive shell"

lw_expect_grep /lib/upgrade/keep.d/lw-history '^/root/\.ash_history$'
echo ok
