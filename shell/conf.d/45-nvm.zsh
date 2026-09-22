# nvm, LAZILY. Inert unless nvm is installed.
#
# Sourcing nvm.sh eagerly costs 943 ms on the author's machine -- measured with
# `MACBOOT_ZSH_PROFILE=1 exec zsh`, where it was 71% of a 1332 ms startup and the single
# most expensive thing in it by an order of magnitude. Every interactive shell paid that,
# whether or not it ever switched node version.
#
# It does not have to be. Symlink node/npm/npx from the nvm default into ~/.local/bin,
# which 00-path.zsh puts first on PATH, and RUNNING node never needs nvm -- only SWITCHING
# versions does:
#
#     for b in node npm npx; do
#       ln -sf "$(dirname "$(nvm which default)")/$b" ~/.local/bin/$b
#     done
#
# That split matters most for non-interactive shells, which never read this file at all;
# this applies the same idea to interactive ones.
#
# So: node/npm/npx work immediately from the symlinks, and nvm.sh is sourced the first time
# you type `nvm`. `nvm use 20` still wins afterwards, because nvm PREPENDS the version's bin
# to PATH and therefore lands ahead of ~/.local/bin.
#
# This block used to be a second fence in ~/.zshrc, which meant it could only be edited,
# not replaced -- and edits in a managed fence are lost. As a unit, a 45-nvm.zsh of your own
# in ~/.config/zsh/conf.d/ replaces this file wholesale. See docs/shell.md.
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

if [[ -s $NVM_DIR/nvm.sh ]]; then
  # The escape hatch, for the one case lazy loading genuinely breaks: a chpwd hook that
  # reads .nvmrc and switches automatically needs nvm defined before you type anything.
  if [[ -n ${MACBOOT_NVM_EAGER:-} ]]; then
    source $NVM_DIR/nvm.sh
    [[ -s $NVM_DIR/bash_completion ]] && source $NVM_DIR/bash_completion
  else
    # `unfunction` first, so the real nvm replaces this shim rather than recursing into it.
    # Completion is loaded here too: nothing can complete `nvm` before `nvm` exists anyway.
    nvm() {
      unfunction nvm
      source $NVM_DIR/nvm.sh
      [[ -s $NVM_DIR/bash_completion ]] && source $NVM_DIR/bash_completion
      nvm "$@"
    }
  fi
fi
