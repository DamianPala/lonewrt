# R37f, R72e: at the first start of a tailscale image the reset note and the greeting come first, then
# the link message; seen on the owner's router on 2026-11-23, where the link came before both.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc
notify_setup ''
ts_on
ts_state not_added
kb_first_start

ts_due link
passes 3
expect_sent 3
case "$(sent_text 1)" in *'Router was reset'*) ;; *) lw_fail "first message is not the reset note: $(sent_text 1)" ;; esac
case "$(sent_text 2)" in *'router bot is ready'*) ;; *) lw_fail "second message is not the greeting: $(sent_text 2)" ;; esac
case "$(sent_text 3)" in *'Add this router to Tailscale'*) ;; *) lw_fail "third message is not the link: $(sent_text 3)" ;; esac
lw_expect_eq "$(ts_marked)" link "events marked"

# later passes and a restart send nothing more
reboot_sim
passes 3
expect_sent 3

no_link_logged
echo ok
