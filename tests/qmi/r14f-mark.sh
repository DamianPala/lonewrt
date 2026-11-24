# R14f: the handler's mark of a negotiating start (the deadline of R73h, a second of the uptime
# clock) lives in the family directory of root under /var/run, mode 0700, never in the public /tmp.
# A directory that is a link, a file or not root's gets no write and no removal; the start itself
# goes on. The mark of a start that was killed stays, which the reader (watchcat) checks.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/qmi/helpers.inc
. /fw/tests/qmi/helpers.inc

D=/var/run/lw-family
mode_of() { ls -ld "$1" | cut -c1-10; }

# a start killed after the mark: the mark holds the deadline (1000 s + 60 s) in a directory of mode 0700
qmi_fixture owner-sim
rm -rf "$D" /tmp/lw-family
qmi_fault '--get-profile-settings' kill
qmi_run setup ipv4v6 >/dev/null || :
lw_expect_eq "$(cat "$D/negotiating")" 1060 'the mark of a killed start'
lw_expect_eq "$(mode_of "$D")" drwx------ 'mode of the family directory'
lw_expect_eq "$(ls -A "$D")" negotiating 'files in the family directory'
[ ! -e /tmp/lw-family ] || lw_fail 'R14f: the mark went to the public /tmp'

# a start that ends takes its mark away
qmi_fixture owner-sim
qmi_run setup ipv4v6 || lw_fail 'a start in a directory with an old mark failed'
lw_expect_eq "$(ls -A "$D")" '' 'the mark after a start that ended'
qmi_ifdown ipv4v6

# the family directory is a link: nothing is written through it, the start works
qmi_fixture owner-sim
rm -rf "$D" /tmp/elsewhere
mkdir /tmp/elsewhere
ln -s /tmp/elsewhere "$D"
qmi_run setup ipv4v6 || lw_fail 'a start with a link as the family directory failed'
lw_expect_eq "$(ls -A /tmp/elsewhere)" '' 'files written through a link'
qmi_ifdown ipv4v6
# and a killed start there leaves nothing either, and a mark already in the target is not removed
qmi_fixture owner-sim
echo 4242 >/tmp/elsewhere/negotiating
qmi_fault '--get-profile-settings' kill
qmi_run setup ipv4v6 >/dev/null || :
lw_expect_eq "$(cat /tmp/elsewhere/negotiating)" 4242 'the file behind a link'
qmi_fixture owner-sim
qmi_run setup ipv4v6 || lw_fail 'the start after a link failed'
lw_expect_eq "$(cat /tmp/elsewhere/negotiating)" 4242 'the file behind a link, after a start that ended'
qmi_ifdown ipv4v6

# a file where the directory should be
qmi_fixture owner-sim
rm -rf "$D"
: >"$D"
qmi_run setup ipv4v6 || lw_fail 'a start with a file as the family directory failed'
[ -f "$D" ] && [ ! -s "$D" ] || lw_fail 'the file in the place of the directory was changed'
qmi_ifdown ipv4v6

# the test of the owner: a directory of another owner is no family directory (/proc belongs to nobody
# in this sandbox)
rm -rf "$D"
mkdir -p "$D"
(
    set +u
    # shellcheck source=/dev/null
    . /lib/functions.sh
    # shellcheck source=/dev/null
    . /lib/netifd/netifd-proto.sh
    INCLUDE_ONLY=1
    # shellcheck source=/dev/null
    . /qmi-overlay/lib/netifd/proto/qmi.sh
    lw_dir_ok "$D" || exit 1
    lw_dir_ok /proc && exit 2
    lw_dir_ok /nonexistent && exit 3
    exit 0
) || lw_fail "lw_dir_ok of the handler, exit $?"
echo ok
