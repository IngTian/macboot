# 60-keys.zsh — keymap and key bindings.
#
# Above 50 because zsh-autosuggestions (80-plugins.zsh) wraps ZLE widgets and must
# see the final keymap; binding keys after it would leave the wrapper attached to
# widgets nothing is bound to any more.

bindkey -e # emacs keymap EXPLICITLY: zsh picks vi silently when $EDITOR matches
# /vi/, so exporting EDITOR=nvim changes how every prompt edits

# Up/Down search history for what is already typed instead of walking every entry.
autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
bindkey '^[[A' up-line-or-beginning-search
bindkey '^[[B' down-line-or-beginning-search
bindkey '^[OA' up-line-or-beginning-search # application cursor mode (tmux, less)
bindkey '^[OB' down-line-or-beginning-search

bindkey '^[[1;5C' forward-word # ctrl-arrow, iTerm2 default sequences
bindkey '^[[1;5D' backward-word
bindkey '^[[H' beginning-of-line
bindkey '^[[F' end-of-line
bindkey '^[[3~' delete-char # fn-delete; unbound in the emacs keymap it inserts `~`
bindkey '^[^?' backward-kill-word
