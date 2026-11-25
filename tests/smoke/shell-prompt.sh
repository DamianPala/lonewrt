# R32b, D220: an interactive login shell has the colored prompt, a TERM the router has terminfo for
# and the aliases of the owner's bashrc; non-interactive shells keep the stock settings.
# shellcheck source=tests/lib.sh
. /fw/tests/lib.sh

noninteractive() {
    # shellcheck disable=SC2016  # Read the child shell's variables.
    env TERM=xterm-ghostty /bin/ash "$1" 'printf "TERM=%s\nPS1=%s\n" "$TERM" "$PS1"; alias'
}
stock_login=$(noninteractive -lc)
stock_command=$(noninteractive -c)
lw_setup

# Terminfo fixtures keep known terminal types and exercise both branches of the title condition.
mkdir -p /usr/share/terminfo/x /usr/share/terminfo/l /usr/share/terminfo/r
: >/usr/share/terminfo/x/xterm-256color
: >/usr/share/terminfo/x/xterm-color
: >/usr/share/terminfo/l/linux
: >/usr/share/terminfo/r/rxvt

# login TERM SCRIPT: the output of SCRIPT in an interactive login ash whose TERM is TERM
login() {
    printf '%s\nexit\n' "$2" | env TERM="$1" /bin/ash -l -i 2>&1
}

# value_of TERM NAME: the value of the variable NAME in that login shell
value_of() {
    login "$1" "printf 'V=%s\n' \"\$$2\"" | sed -n 's/^.*V=//p'
}

lw_expect_eq "$(value_of xterm-ghostty TERM)" xterm-256color "TERM of Ghostty without an entry"
exported=$(login xterm-ghostty 'env | command grep "^TERM="' | sed -n 's/^.*TERM=//p')
lw_expect_eq "$exported" xterm-256color "fallback TERM exported to child commands"
lw_expect_eq "$(value_of xterm-color TERM)" xterm-color "a TERM with an entry"
lw_expect_eq "$(value_of xterm-256color TERM)" xterm-256color "TERM xterm-256color with an entry"
lw_expect_eq "$(value_of '' TERM)" "" "an empty TERM"
lw_expect_eq "$(value_of dumb TERM)" dumb "TERM dumb"

reset='\[\033[00m\]'
colors='\[\033[01;31m\]\u'"$reset"'@\[\033[01;32m\]\h'"$reset"
colors="$colors"':\[\033[01;34m\]\w'"$reset"'\$ '
title='\[\e]0;\u@\h: \w\a\]'
lw_expect_eq "$(value_of xterm-ghostty PS1)" "$title$colors" "prompt and title after fallback"
lw_expect_eq "$(value_of rxvt PS1)" "$title$colors" "colored prompt and title for rxvt"
lw_expect_eq "$(value_of linux PS1)" "$colors" "colored prompt without a title for linux"

lw_expect_eq "$(value_of dumb PS1)" '\u@\h:\w\$ ' "plain prompt for TERM dumb"

lw_expect_eq "$(noninteractive -lc)" "$stock_login" "non-interactive login keeps stock settings"
lw_expect_eq "$(noninteractive -c)" "$stock_command" "ash -c command keeps stock settings"

# every alias runs in the rootfs (busybox takes each option), and .. goes up one directory
# shellcheck disable=SC2016  # Run pwd after the alias in the login shell.
out=$(login xterm-256color 'alias ls ll la l grep df free .. >/dev/null && echo "ok aliases"
ls / >/dev/null && echo "ok ls"
ll / >/dev/null && echo "ok ll"
la / >/dev/null && echo "ok la"
l / >/dev/null && echo "ok l"
grep root /etc/passwd >/dev/null && echo "ok grep"
df / >/dev/null && echo "ok df"
free >/dev/null && echo "ok free"
cd /usr/bin && .. && echo "ok .. $(pwd)"' | sed -n 's/^.*\(ok .*\)$/\1/p')
for want in "ok aliases" "ok ls" "ok ll" "ok la" "ok l" "ok grep" "ok df" "ok free" "ok .. /usr"; do
    printf '%s\n' "$out" | grep -qxF "$want" || lw_fail "alias check '$want' missing in: $out"
done
echo ok
