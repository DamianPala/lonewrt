# R41d, R38: /speedtest next to the real service loop. A test runs as a process of its own: an SMS
# and another command are answered while it runs, the result follows, and no way of stopping the
# service (TERM, TERM while Telegram hangs, kill -9, everything killed) leaves a speed test
# process or a state that blocks the next test. Also the time budget of R41: the whole test is at
# most 110 s, so the result lands inside the 120 s.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh
# shellcheck source=tests/notify/helpers.inc
. /fw/tests/notify/helpers.inc

notify_setup ''
# R41: the defaults, as the image has them (the tests shorten them through the environment)
# shellcheck disable=SC2016  # the variables are for the inner shell
defaults=$(env -u LW_NOTIFY_ST_LIMIT -u LW_NOTIFY_ST_TOTAL -u LW_NOTIFY_ST_POLL sh -c \
    '. /usr/lib/lw/common.sh; . /usr/lib/lw/notify.sh; . /usr/lib/lw/speedtest.sh;
     echo "$NT_ST_LIMIT $NT_ST_TOTAL $NT_ST_POLL"')
read -r limit total poll _ <<DEFAULTS
$defaults
DEFAULTS
[ "$total" -le 110 ] || lw_fail "whole test is $total s, over the 110 s of R41d"
# the tool, then the plain ping after a failure (two hosts, 5 s each), inside the whole
[ $((limit + 10)) -le "$total" ] || lw_fail "limit $limit s + ping does not fit in $total s"
# worst case to the chat: the whole test, the next pass, one Telegram call of 5 s (a Telegram that
# hangs for its full limit cannot be held to any bound)
[ $((total + poll + 5)) -le 120 ] || lw_fail "result later than 120 s: $total + $poll + 5"

lw_net up down
export LW_NOTIFY_CLOCK=/proc/uptime LW_NOTIFY_POLL=2 LW_NOTIFY_LONGPOLL=1
export LW_NOTIFY_ST_LIMIT=40 LW_NOTIFY_ST_TOTAL=50

# wait_sent N MAX: up to MAX s until the bot has sent N messages
wait_sent() {
    _i=0
    while [ "$(sent)" -lt "$1" ] && [ "$_i" -lt "$2" ]; do
        sleep 1
        _i=$((_i + 1))
    done
    [ "$(sent)" -ge "$1" ] || lw_fail "only $(sent) of $1 messages after $2 s"
    echo "$_i"
}
# gone PID MAX: PID ends within MAX s
gone() {
    _i=0
    while kill -0 "$1" 2>/dev/null && [ "$_i" -lt "$2" ]; do
        sleep 1
        _i=$((_i + 1))
    done
    ! kill -0 "$1" 2>/dev/null || lw_fail "process $1 still there after $2 s"
}
# st_orphans: any process of the service, the worker or the client is left
st_orphans() {
    ! pgrep -f 'lw-notify|stubs/speedtest|sleep 3601|timeout --foreground' >/dev/null || {
        ps >&2
        lw_fail "left over: $1"
    }
}
start_service() {
    lw-notify run </dev/null >/dev/null 2>&1 &
    svc=$!
    sleep 3
}

# ---- a 14 s test: an SMS and a command are answered meanwhile (R41d, R34: 30 s)
st_mode ok 14
start_service
tg_push "$TG_CHAT" /speedtest
t=$(wait_sent 1 6)
lw_expect_eq "$(sent_text 1)" "⏱ Speed test started, result in about 60 s." "start reply"
[ "$t" -le 4 ] || lw_fail "the start reply took $t s"
pgrep -f 'lw-notify speedtest-run' >/dev/null || lw_fail "no worker after the start"
sms_in 1 +38200000001 '11/07/26 10:00:00' 'arrives while the test runs'
t=$(wait_sent 2 12)
[ "$t" -le 10 ] || lw_fail "the SMS took $t s during a test"
pgrep -f 'lw-notify speedtest-run' >/dev/null || lw_fail "the test ended before the SMS: too fast"
expect_last 'arrives while the test runs'
tg_push "$TG_CHAT" /help
t=$(wait_sent 3 8)
[ "$t" -le 6 ] || lw_fail "/help took $t s during a test"
tg_push "$TG_CHAT" /speedtest
t=$(wait_sent 4 8)
lw_expect_eq "$(last_text)" "⏳ A speed test is already running, the result comes in a moment." \
    "second command"
# the result arrives a few seconds after the client ends (poll cap while a test is on)
t=$(wait_sent 5 20)
case $(last_text) in '🚀 Speed test: fast'*) ;; *) lw_fail "no result: $(last_text)" ;; esac
lw_expect_eq "$(st_calls)" 1 "one client for two commands"
kill "$svc"
gone "$svc" 6
sleep 1
st_orphans "after a test that ended"

# ---- while a test is on the long poll is short, so the result is picked up soon after the client
# ends; without a test it is the full time
export LW_NOTIFY_POLL=20 LW_NOTIFY_LONGPOLL=10
st_mode ok 6
rm -f "$G/polls"
start_service
sleep 2
lw_expect_grep "$G/polls" '^10$'
n=$(sent)
tg_push "$TG_CHAT" /speedtest
wait_sent $((n + 1)) 12 >/dev/null
lines=$(wc -l <"$G/polls")
sleep 4
# the poll that was already running when the command came may be long; every later one is short
tail -n +"$((lines + 2))" "$G/polls" | grep -v '^$' | grep -qvx '[0-1]' &&
    lw_fail "long poll while a test runs: $(tail -n +"$((lines + 2))" "$G/polls" | tr '\n' ' ')"
wait_sent $((n + 2)) 12 >/dev/null
kill "$svc"
gone "$svc" 6
export LW_NOTIFY_POLL=2 LW_NOTIFY_LONGPOLL=1

# ---- TERM during a test: nothing is left, and the next start has no stuck state
rm -f "$T/speedtest/calls"
st_mode hang
export LW_NOTIFY_ST_LIMIT=60 LW_NOTIFY_ST_TOTAL=70
start_service
n=$(sent)
tg_push "$TG_CHAT" /speedtest
wait_sent $((n + 1)) 6 >/dev/null
pgrep -f 'stubs/speedtest|sleep 3601' >/dev/null || lw_fail "no client running"
kill "$svc"
gone "$svc" 6
sleep 1
st_orphans "TERM during a test"
[ ! -e /tmp/lw-notify/speedtest.pid ] || lw_fail "pid file kept after TERM"
# the same service start has no "already running" and runs the next test
st_mode ok
start_service
n=$(sent)
tg_push "$TG_CHAT" /speedtest
wait_sent $((n + 2)) 12 >/dev/null
case $(last_text) in '🚀 Speed test: fast'*) ;; *) lw_fail "no test after TERM: $(last_text)" ;; esac
lw_expect_eq "$(st_calls)" 2 "clients after TERM and a new command"
kill "$svc"
gone "$svc" 6

# ---- TERM while Telegram does not answer: the handler waits for the call in flight (procd
# would send KILL after 5 s); the test goes down with the service either way
st_mode hang
start_service
n=$(sent)
tg_push "$TG_CHAT" /speedtest
wait_sent $((n + 1)) 6 >/dev/null
echo hang >"$G/net"
sleep 1
kill "$svc"
gone "$svc" 12
sleep 1
st_orphans "TERM with Telegram hanging"
echo up >"$G/net"

# ---- kill -9 of the service: no handler runs, the watchdog of the test ends it
start_service
n=$(sent)
tg_push "$TG_CHAT" /speedtest
wait_sent $((n + 1)) 6 >/dev/null
pgrep -f 'stubs/speedtest|sleep 3601' >/dev/null || lw_fail "no client running"
kill -9 "$svc"
sleep 4
st_orphans "kill -9 of the service"
# the pid file is still there; the new service ignores it and runs a test
[ -e /tmp/lw-notify/speedtest.pid ] || lw_fail "expected the stale pid file of a killed service"
st_mode ok
start_service
n=$(sent)
tg_push "$TG_CHAT" /speedtest
wait_sent $((n + 2)) 12 >/dev/null
case $(sent_text $((n + 1))) in
    '⏱ Speed test started'*) ;;
    *) lw_fail "the stale state answered: $(sent_text $((n + 1)))" ;;
esac
case $(last_text) in '🚀 Speed test: fast'*) ;; *) lw_fail "no result: $(last_text)" ;; esac
kill "$svc"
gone "$svc" 6

# ---- kill -9 of everything (service, worker, client): a stale lock does not block (R41c)
st_mode hang
start_service
n=$(sent)
tg_push "$TG_CHAT" /speedtest
wait_sent $((n + 1)) 6 >/dev/null
pid=$(cat /tmp/lw-notify/speedtest.pid)
kill -9 "$svc"
kill -9 "-$pid"
sleep 2
st_orphans "kill -9 of everything"
[ -e /tmp/lw-notify/speedtest.pid ] || lw_fail "expected a stale pid file"
st_mode ok
start_service
n=$(sent)
tg_push "$TG_CHAT" /speedtest
wait_sent $((n + 2)) 12 >/dev/null
case $(sent_text $((n + 1))) in
    '⏱ Speed test started'*) ;;
    *) lw_fail "a stale lock answered: $(sent_text $((n + 1)))" ;;
esac
case $(last_text) in '🚀 Speed test: fast'*) ;; *) lw_fail "no result: $(last_text)" ;; esac
# no message about the dead test, and the log stays empty (R34c)
for i in $(seq 1 "$(sent)"); do
    case $(sent_text "$i") in *'did not finish'*) lw_fail "message about a dead test" ;; esac
done
lw_expect_eq "$(cat "$T/syslog")" "" "syslog"
kill "$svc"
gone "$svc" 6

# ---- the worker overruns the whole-test limit: the wrapper ends the worker, its watchdog and the
# client together, while the service keeps running
st_mode hang
export LW_NOTIFY_ST_LIMIT=20 LW_NOTIFY_ST_TOTAL=3
start_service
n=$(sent)
tg_push "$TG_CHAT" /speedtest
wait_sent $((n + 2)) 12 >/dev/null
expect_last 'did not finish in time'
sleep 4
! pgrep -f 'speedtest-run|speedtest --output|sleep 3601' >/dev/null ||
    lw_fail "left over after the whole-test limit: $(ps)"
kill "$svc"
gone "$svc" 6
sleep 1
st_orphans "end"
echo ok
