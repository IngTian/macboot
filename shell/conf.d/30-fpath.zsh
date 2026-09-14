# 30-fpath.zsh — where zsh looks for completion functions.
#
# Numbered below 50 on purpose: 50-compinit.zsh consumes $fpath, so anything that
# adds to it must run before that. If you install a tool that ships zsh completions,
# add them from a file numbered below 50 (e.g. ~/.config/zsh/conf.d/40-mytool.zsh).

fpath=(
  $HOMEBREW_PREFIX/share/zsh-completions(N-/)
  $HOMEBREW_PREFIX/share/zsh/site-functions(N-/)
  $fpath
)
# typeset -U fpath is declared in 00-path.zsh, so re-running this is idempotent.
