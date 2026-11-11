# R49c: --apn, --auth-type, --username and --password go into the start-network call only when the
# option of network.wwan is set, in the order of qmi.sh, before --autoconnect; the login never
# reaches the log.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/linkwatch/helpers.inc
. /fw/tests/linkwatch/helpers.inc
call() { grep -e --start-network "$CALLS"; }
base="-s -d /tmp/cdc-wdm0 -t 5000 --set-client-id wds,17 --start-network"

# only the APN
lk_setup
uci set network.wwan.apn=fake.apn.q7x9
uci commit network
lk_lost
lw-linkwatch once
lw_expect_eq "$(call)" "$base --apn fake.apn.q7x9 --autoconnect" "call with an APN only"

# all four
lk_setup
uci set network.wwan.apn=fake.apn.q7x9
uci set network.wwan.auth=pap
uci set network.wwan.username=fakeuser-q7x9
uci set network.wwan.password=fakepass-q7x9
uci commit network
lk_lost
lw-linkwatch once
lw_expect_eq "$(call)" "$base --apn fake.apn.q7x9 --auth-type pap --username fakeuser-q7x9 --password fakepass-q7x9 --autoconnect" \
    "call with all options"
lw_expect_no_grep "$LKS" fakepass-q7x9
lw_expect_no_grep "$LKS" fakeuser-q7x9

# an option set to nothing is not passed
lk_setup
uci set network.wwan.apn=fake.apn.q7x9
uci set network.wwan.auth=''
uci commit network
lk_lost
lw-linkwatch once
lw_expect_eq "$(call)" "$base --apn fake.apn.q7x9 --autoconnect" "call with an empty auth"
echo ok
