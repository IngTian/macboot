# 80-plugins.zsh — third-party shell integrations. Loaded last, on purpose:
# zsh-autosuggestions wraps ZLE widgets and must see the final keymap from
# 60-keys.zsh, and fzf's key-bindings.zsh rebinds ^R over whatever came before.
#
# A prompt is deliberately out of scope. macboot does not ship or configure
# powerlevel10k: the author's own .p10k.zsh is 90 KB of answers to a wizard that
# cannot be regenerated to the same state, and guessing a stranger's prompt is not a
# bootstrap's job. Set PS1, or install a prompt, from your own drop-in
# (~/.config/zsh/conf.d/90-prompt.zsh) or below the fence in ~/.zshrc.

: "${HOMEBREW_PREFIX:=/opt/homebrew}"

# ---------------------------------------------------------------------------
# zsh-autosuggestions
# ---------------------------------------------------------------------------
ZSH_AUTOSUGGEST_STRATEGY=(history completion) # read at suggest time; set first
ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=80 # no suggestion work on pasted multi-line blobs
if [[ -r $HOMEBREW_PREFIX/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]]; then
  source $HOMEBREW_PREFIX/share/zsh-autosuggestions/zsh-autosuggestions.zsh
fi

# ---------------------------------------------------------------------------
# fzf
# ---------------------------------------------------------------------------
# `source <(fzf --zsh)` needs fzf >= 0.48 and forks twice per shell; the shipped files
# are the same content and cost nothing.
#
# Measured caveat, left alone on purpose: both fzf files snapshot `setopt` and restore
# it in one eval whose list includes the read-only `zle`, so a `zsh -i -c` (how hooks
# and CI drive zsh) prints "can't change option: zle" twice. It is cosmetic, it comes
# from fzf's own shipped file, and the alternatives — skipping fzf or swallowing its
# stderr — either lose ^R or hide real errors.
[[ -r $HOMEBREW_PREFIX/opt/fzf/shell/completion.zsh ]] &&
  source $HOMEBREW_PREFIX/opt/fzf/shell/completion.zsh
[[ -r $HOMEBREW_PREFIX/opt/fzf/shell/key-bindings.zsh ]] &&
  source $HOMEBREW_PREFIX/opt/fzf/shell/key-bindings.zsh

# ---------------------------------------------------------------------------
# autojump — the `j` command
# ---------------------------------------------------------------------------
# autojump ships a shell FUNCTION, because a jump has to cd in the current shell.
# `alias j=autojump` looks equivalent and is not: the binary only PRINTS the directory
# it picked, so `j foo` would echo a path and leave you where you were.
if [[ -r $HOMEBREW_PREFIX/etc/profile.d/autojump.sh ]]; then
  source $HOMEBREW_PREFIX/etc/profile.d/autojump.sh
elif ((${+commands[autojump]})); then
  # Reported rather than swallowed: the binary being present while the integration
  # file is not means a partial or relocated brew install, and `j` silently not
  # existing is the confusing form of that.
  print -u2 "  ! autojump: no $HOMEBREW_PREFIX/etc/profile.d/autojump.sh, so \`j\` is unavailable"
fi
# zoxide is deliberately NOT wired up even when installed: it and autojump both want
# to own directory jumping, they keep separate databases, and having both means `j`
# and `z` disagree about where you have been. Pick one, in your own drop-in.

true
