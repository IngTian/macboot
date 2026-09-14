# 70-aliases.zsh — aliases and tiny shell functions.
#
# Every entry naming an optional tool is guarded. An unguarded `alias ls='eza -l'` on
# a machine where `make optional` was never run gives a shell whose ls prints
# "command not found: eza" forever, and the user has no idea which of their dotfiles
# did it. Guarding costs one builtin lookup per alias.
#
# Nothing here aliases `python`, `pip` or `grep`. Aliasing a language entry point is
# how the audited machine ended up with four projects resolving python against conda
# base; aliasing `grep` to `rg` breaks every `grep -e` / `grep -r` invocation muscle
# memory produces, because the flags are not the same language.
#
# To replace this file wholesale, write your own ~/.config/zsh/conf.d/70-aliases.zsh
# — same basename wins. To drop it entirely, make that file empty.

# $+commands is zsh's own hash lookup: no fork, unlike `command -v`, which matters
# when ~20 guards run on every single shell start.
_macboot_has() { (($+commands[$1])); }

: "${HOMEBREW_PREFIX:=/opt/homebrew}" # set by 00-path.zsh; defaulted for safety

# ---------------------------------------------------------------------------
# Listing
# ---------------------------------------------------------------------------
if _macboot_has eza; then
  alias ls='eza --group-directories-first'
  alias ll='eza -l --git --group-directories-first'
  alias la='eza -la --git --group-directories-first'
  alias lt='eza --tree --level=2 --group-directories-first'
else
  # BSD ls, not GNU: -G is colour here and "print group" on Linux, so this pair of
  # aliases is not portable and is not meant to be.
  alias ls='ls -G'
  alias ll='ls -lhG'
  alias la='ls -lahG'
fi

# --paging=never: without it `cat somefile` opens less, so a one-line file needs a
# `q` to get the prompt back.
_macboot_has bat && alias bcat='bat --style=plain --paging=never'
# Deliberately NOT `alias cat=bat`. Aliases do not apply to scripts, but they DO
# apply to anything you paste into an interactive shell, and `cat` appears inside
# pasted one-liners constantly; bat's tty detection usually saves it, which makes the
# failures rare enough to be baffling rather than obvious.

# ---------------------------------------------------------------------------
# Git — git is a must-have (Xcode CLT ships one), so these are unguarded.
# ---------------------------------------------------------------------------
alias g='git'
alias gs='git status -sb'
alias gd='git diff'
alias gds='git diff --staged'
# `git log` with no limit pipes into less and, in a repo with 100k commits, the first
# page is all you ever read; -20 makes it a glance instead of a session.
alias gl='git log --oneline --graph --decorate -20'

# ---------------------------------------------------------------------------
# Navigation
# ---------------------------------------------------------------------------
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

mkcd() {
  # mkdir then cd, as one step. -p so `mkcd a/b/c` works, and `|| return` so a failed
  # mkdir does not leave you silently in the old directory believing it worked.
  mkdir -p -- "$1" || return
  cd -- "$1" || return
}

# ---------------------------------------------------------------------------
# Shell / PATH hygiene — the theme of 00-path.zsh, made inspectable
# ---------------------------------------------------------------------------
alias path='print -l -- $path'
alias fpath='print -l -- $fpath'

# `exec zsh`, not `source ~/.zshrc`: re-sourcing runs compinit a second time and
# re-registers zsh-autosuggestions' ZLE widgets on top of themselves. A fresh exec is
# the only reload that ends in a known state. -l so ~/.zprofile is re-read too.
alias reload='exec zsh -l'

# Which drop-in is costing you the startup time. See shell/rc.zsh.
alias zprofile='MACBOOT_ZSH_PROFILE=1 exec zsh'

# ---------------------------------------------------------------------------
# Misc, each earning its place
# ---------------------------------------------------------------------------
alias df='df -h'
alias du='du -h'
# -nP: no DNS and no /etc/services lookup, which is the difference between instant
# output and a 20-second hang offline.
alias ports='lsof -nP -iTCP -sTCP:LISTEN'
# en0 is Wi-Fi on laptops and Ethernet on desktops; the fallback covers the other.
alias localip='ipconfig getifaddr en0 || ipconfig getifaddr en1'

# ripgrep skips dotfiles by default, so a search for a key in ~/.config finds nothing
# and reads as "not there". --hidden without excluding .git buries the answer under
# packfile noise.
_macboot_has rg && alias rgh='rg --hidden --glob "!.git"'

_macboot_has fd && alias fda='fd --hidden --no-ignore'
_macboot_has jq && alias jqc='jq -C . | less -R' # -R or the colour codes print raw

unfunction _macboot_has # guards are resolved; do not leak a helper into the session

# A final command that cannot fail: a guard that evaluated false would otherwise
# leave $? non-zero, and a themed prompt renders an error marker on the very first
# prompt of every new shell.
true
