# powerlevel10k, the prompt. Inert unless p10k is installed.
#
# `90`, i.e. after 80-plugins.zsh, because a prompt has to win. zsh-autosuggestions and
# fzf's key bindings both wrap ZLE widgets, and a theme loaded before them can have its
# prompt or its keymap quietly replaced.
#
# TWO LOCATIONS, checked in this order, and both are real:
#   * Homebrew's, which is what a fresh machine gets from the Brewfile.
#   * ~/powerlevel10k, the git clone from p10k's own install instructions. The author's
#     machine has had this since long before macboot existed, and a bootstrap that only
#     looked in the brew prefix would silently leave such a machine promptless.
#
# macboot does NOT own your ~/.p10k.zsh, and that line is deliberate. That file is ~90 KB
# of answers to the `p10k configure` wizard, it cannot be regenerated to the same state
# from anything in a repo, and it encodes taste at a level no bootstrap should have an
# opinion about. This unit sources it if it exists and says nothing if it does not; run
# `p10k configure` to create it.
: "${HOMEBREW_PREFIX:=/opt/homebrew}" # set by 00-path.zsh; defaulted for safety

if [[ -r $HOMEBREW_PREFIX/share/powerlevel10k/powerlevel10k.zsh-theme ]]; then
  source $HOMEBREW_PREFIX/share/powerlevel10k/powerlevel10k.zsh-theme
elif [[ -r $HOME/powerlevel10k/powerlevel10k.zsh-theme ]]; then
  source $HOME/powerlevel10k/powerlevel10k.zsh-theme
fi

# Your wizard output. Sourced last so it overrides the theme's defaults, which is the order
# p10k's own instructions use.
if [[ -r $HOME/.p10k.zsh ]]; then
  source $HOME/.p10k.zsh
fi
