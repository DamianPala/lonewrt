# R46, D65: which sender numbers are admins. The sender loses "+", a leading 00 or a single leading 0
# and must have at least 8 digits left; it matches when an admin number (without "+" and 00) ends
# with them. A national form (067..., or 9 digits with no prefix) matches the international entry;
# 7 digits do not; a foreign sender in international form does not match, but one that arrives with
# the same 8 final digits and no country code does (accepted). The reply goes to the matched admin
# number, without a plus (the installed sms_tool encodes "+" as a digit). All numbers here are fake.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
export LW_SMSCTL_MAX=1000
notify_setup ''
admins_set '+38267000001,+48600000001,0044790000002,+1234567'
lw_net up down
passes 2

# match SENDER REPLY_TO: the sender is an admin and the reply goes to REPLY_TO
match() {
    _n=$(sms_out)
    sms_cmd "$1" 'HELP'
    lw_expect_eq "$(sms_out)" $((_n + 1)) "reply to sender '$1'"
    lw_expect_eq "$(sms_to $((_n + 1)))" "$2" "reply number for sender '$1'"
}
# nomatch SENDER: no reply
nomatch() {
    _n=$(sms_out)
    sms_cmd "$1" 'HELP'
    lw_expect_eq "$(sms_out)" "$_n" "reply to sender '$1'"
}

match +38267000001 38267000001
match 38267000001 38267000001
match 0038267000001 38267000001
# the national form of the SIM's country: the reply goes to the list entry
match 067000001 38267000001
# a Polish number written without any prefix, and with a leading 0
match 600000001 48600000001
match 0600000001 48600000001
match +48600000001 48600000001
# the list entry was written with 00
match +44790000002 44790000002
match 0790000002 44790000002

# 7 digits are not enough, with or without the leading 0
nomatch 7000001
nomatch 07000001
# a list entry of 7 digits can never be matched (the sender needs 8)
nomatch 1234567
nomatch 01234567
# a foreign number in international form is another number
nomatch +4467000001
nomatch +38267000002
nomatch +48600000011
# the same 8 final digits and no country code: accepted as the admin (a different country cannot be
# told apart)
match 67000001 38267000001
# short codes and names
nomatch 1466
nomatch Telekom
nomatch ''
echo ok
