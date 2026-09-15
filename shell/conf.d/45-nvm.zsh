# nvm, for interactive shells. Inert unless nvm is installed.
#
# This used to be a SECOND fence that scripts/40-node.sh wrote into ~/.zshrc, next to
# macboot's own `macboot:shell` fence. That was the wrong shape twice over:
#
#   * It gave nvm special treatment. Every other thing macboot configures for zsh is a
#     numbered unit in this directory; nvm alone got its own block in the user's rc file,
#     so `.zshrc` could not shrink to the single `source` line the design is built around.
#   * A block in .zshrc cannot be overridden the way a unit can. Dropping your own
#     45-nvm.zsh into ~/.config/zsh/conf.d/ now replaces this file entirely (rc.zsh keys
#     units by basename and reads yours second), which is how every other unit here works.
#
# Non-interactive shells deliberately do NOT get this. Sourcing nvm.sh is 1000+ lines of
# shell and the slowest thing in a zsh startup; hooks, LaunchAgents and cron get node from
# the ~/.local/bin symlinks that 40-node.sh writes instead, which is the whole reason that
# module exists. Do not "fix" this by moving it to .zshenv.
#
# NVM_DIR is exported rather than assumed: nvm.sh reads it, and `nvm install` writes there.
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [[ -s $NVM_DIR/nvm.sh ]]; then
  source $NVM_DIR/nvm.sh
fi
# nvm's completion is bash-shaped; zsh loads it fine and it is the only reason to source a
# second file. Guarded separately because a partial nvm install can have one without the other.
if [[ -s $NVM_DIR/bash_completion ]]; then
  source $NVM_DIR/bash_completion
fi
