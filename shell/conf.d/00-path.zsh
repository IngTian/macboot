# 00-path.zsh — Homebrew prefix and PATH. Assembled exactly once, here.
#
# This is the point of the whole conf.d layout. The audited machine prepended conda
# base to PATH from ~/.zshrc, so four projects (Paper6R, watchboard, market-witness,
# tokscale) resolved `python` against a base env holding 217 pip packages without
# anyone choosing that. The lesson is not "conda bad", it is: PATH is assembled in
# ONE file, in a stated order, and no language manager gets to prepend an interpreter
# directory behind your back.

# Resolved by testing for the binary rather than `eval "$(brew shellenv)"`: shellenv
# costs a subprocess on every shell start AND prepends brew to PATH, which would
# silently override the order established below.
if [[ -x /opt/homebrew/bin/brew ]]; then
  export HOMEBREW_PREFIX=/opt/homebrew
elif [[ -x /usr/local/bin/brew ]]; then
  export HOMEBREW_PREFIX=/usr/local
else
  export HOMEBREW_PREFIX=/opt/homebrew # not installed yet; the (N-/) globs drop it
fi

# Ordering, and why each entry sits where it does:
#
#   1. ~/.local/bin   uv itself and everything from `uv tool install`. Ahead of
#                     /usr/bin so it beats /usr/bin/python3 (3.9.6, no pip).
#   2. brew bin/sbin  the toolchain the rest of this repo assumes.
#   3. $path          system defaults (/usr/bin /bin /usr/sbin /sbin), untouched.
#   4. ~/go/bin, ~/.cargo/bin
#                     build outputs, APPENDED on purpose. A project-local toolchain
#                     (go.mod's `toolchain`, rust-toolchain.toml) must win over
#                     whatever was last installed globally, and a venv's bin/
#                     prepended by activation must win over all of it.
#
# Safe to do this in a .zshrc-loaded file specifically because macOS runs
# /usr/libexec/path_helper from /etc/zprofile, which REORDERS PATH and puts the
# system entries first. That happens before ~/.zshrc, so anything set here survives;
# the same lines in ~/.zshenv would be silently reshuffled on every login shell.
#
# typeset -U keeps the first occurrence of each entry only. Without it every
# `exec zsh` / tmux / nested login shell appends another copy, which is how a PATH
# ends up 40 entries long with 12 duplicates and no line to blame.
typeset -U path fpath
path=(
  ~/.local/bin(N-/)
  $HOMEBREW_PREFIX/bin(N-/)
  $HOMEBREW_PREFIX/sbin(N-/)
  $path
  ~/go/bin(N-/)
  ~/.cargo/bin(N-/)
)
export PATH
# (N-/) = drop the entry unless it exists and is a directory (following symlinks).
# Without it a fresh machine carries ~/go/bin in PATH before Go is installed and
# every command miss pays a stat on a path that can never match.

# MANPATH is deliberately NOT set. Measured on macOS 15: with MANPATH unset,
# /usr/bin/manpath already reports /opt/homebrew/share/man, because it derives entries
# from PATH. Exporting a single-entry MANPATH would REPLACE that derived list rather
# than extend it, breaking `man ls`.
#
# INFOPATH is deliberately NOT set either. There is no `info` binary on macOS, so it
# pointed a reader that does not exist at files nobody reads — and because zsh has no
# tied `infopath` array, the usual `INFOPATH=new:$INFOPATH` idiom grew it by one copy
# per shell start without bound (measured: three copies after three `exec zsh`).
