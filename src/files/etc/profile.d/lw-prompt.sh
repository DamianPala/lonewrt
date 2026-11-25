# R32b, D220: an interactive login shell gets a readable prompt and the aliases of the owner's server
# bashrc. The stock /etc/profile sets PS1 and its window-title escape before this file runs, so this
# file replaces both. A non-interactive shell (scripts, ssh router cmd) reads none of it.
case $- in
    *i*) ;;
    *) return 0 ;;
esac

# R32b: the router has terminfo only for the terminals of the image; vim and less need an entry for
# the TERM the connection sends (Ghostty sends xterm-ghostty). An empty TERM and dumb stay as they are.
case "$TERM" in
    '' | dumb) ;;
    *)
        _lw_first=${TERM%"${TERM#?}"}
        [ -f "/usr/share/terminfo/$_lw_first/$TERM" ] || TERM=xterm-256color
        unset _lw_first
        ;;
esac

if [ "$(id -u)" -eq 0 ]; then
    _lw_user='\[\033[01;31m\]'
else
    _lw_user='\[\033[01;36m\]'
fi
_lw_reset='\[\033[00m\]'

if [ "$TERM" = dumb ]; then
    PS1='\u@\h:\w\$ '
else
    PS1="${_lw_user}\u${_lw_reset}@\[\033[01;32m\]\h${_lw_reset}:\[\033[01;34m\]\w${_lw_reset}"'\$ '
fi

case "$TERM" in
    xterm* | rxvt*) PS1='\[\e]0;\u@\h: \w\a\]'"$PS1" ;;
esac

unset _lw_user _lw_reset

alias ls='ls --color=auto'
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias df='df -h'
alias free='free -h'
alias ..='cd ..'
