#!/usr/bin/env bash
# 40-node.sh -- nvm, plus the one arrangement in this repo that a naive test passes
# while it is broken.
#
# nvm is a shell function sourced from ~/.zshrc, and zsh reads ~/.zshrc for
# INTERACTIVE shells only. Measured on the source machine in a clean environment:
#
#   env -i HOME=$HOME /bin/zsh  -c 'command -v node'  -> not found
#   env -i HOME=$HOME /bin/zsh -lc 'command -v node'  -> ALSO not found
#
# The second one surprises people: a login-but-non-interactive shell reads
# ~/.zprofile and skips ~/.zshrc entirely. node therefore exists only inside
# interactive shells, and anything spawned by a Claude Code hook, a LaunchAgent or
# cron gets none -- the failure this is a spec requirement over, not a nicety.
#
# Fix: symlink the nvm default's node/npm/npx into ~/.local/bin, not a
# version-pinned PATH line in ~/.zshenv -- that line names v22.11.0 forever and
# points into a deleted directory after the next `nvm install --lts`, while a
# symlink is one file whose target `readlink` prints and a re-run re-points.
set -euo pipefail
# shellcheck source=lib/common.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

#: Pinned tag, measured: v0.40.1 is the nvm on the source machine. Never install/
#: master -- that is a curl|bash of whatever landed on a branch this morning.
NVM_VERSION="v0.40.1"
NVM_INSTALLER_URL="https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh"

#: Deliberately NOT named NVM_DIR: this script is normally run from an interactive
#: zsh that already exports NVM_DIR=$HOME/.nvm, so inheriting it would point a
#: MACBOOT_HOME=/tmp/scratch test at the real ~/.nvm and install for real.
MACBOOT_NVM_DIR="$MACBOOT_HOME/.nvm"

#: Already first in PATH for interactive shells (shell/conf.d/00-path.zsh); the
#: fence written below is what puts it in PATH for the non-interactive ones.
LOCAL_BIN="$MACBOOT_HOME/.local/bin"

usage() {
  cat <<'EOF'
Usage: 40-node.sh [--dry-run]

Installs nvm into ~/.nvm, sources it from ~/.zshrc, installs the current LTS and
aliases it default, then symlinks node/npm/npx into ~/.local/bin so that hooks,
LaunchAgents and cron can find node -- verified in a clean environment, because an
inherited-PATH check gives a false pass.

EOF
}

# ---------------------------------------------------------------------------

# ok_live <msg> -- ok(), but silent in a dry run. run() returns 0 there without
# doing anything, so an unconditional ok() afterwards reports "installed" about a
# machine nothing touched, and a dry-run transcript has to read as true.
ok_live() { [ "$DRY_RUN" = "1" ] || ok "$*"; }

# nvm_read <nvm subcommand...> -- run nvm in a throwaway bash and print its output.
# Read-only, so no run(): sourcing nvm.sh only defines functions. --no-use keeps it
# from activating a version and prepending to PATH, which would make the paths we
# parse depend on the order these helpers happen to be called in.
nvm_read() {
  bash -c 'export NVM_DIR="$1"; shift
    [ -s "$NVM_DIR/nvm.sh" ] || exit 1
    . "$NVM_DIR/nvm.sh" --no-use >/dev/null 2>&1 || exit 1
    "$@"' macboot-nvm-read "$MACBOOT_NVM_DIR" "$@" 2>/dev/null
}

# default_bin_dir -- the bin/ of whatever `default` currently resolves to, or empty.
# `nvm which default` does the resolving on purpose: an alias may point at another
# alias (default -> lts/* -> lts/jod -> v22.x), and a hand-rolled reader of
# $NVM_DIR/alias/default stops at the first hop and links the wrong version.
# ALWAYS returns 0. The `case` used to end on `[ -x "$p" ] && dirname "$p"`, whose
# status is the function's status, so a path that matched but was not executable
# returned 1 -- and `bin="$(default_bin_dir)"` is a bare assignment under
# `set -euo pipefail`, which terminates the shell silently. That would have exited AFTER
# writing the .zshenv node-path fence and BEFORE linking anything, with no die message,
# no warn and no summary box: a truncated transcript with no stated reason. The
# asymmetry was the tell -- the identical call at install_node_lts sits inside an `if`,
# where set -e is suspended.
default_bin_dir() {
  p="$(nvm_read nvm which default)" || return 0
  case "$p" in
    */bin/node)
      if [ -x "$p" ]; then dirname "$p"; fi
      ;;
  esac
  return 0
}

# default_alias_target -- what `default` points at, ONE hop, verbatim.
#
# Reading the alias file is correct here, unlike resolution: the question is what the
# alias is set TO, which is exactly one hop, and nvm has no command that prints it
# unresolved and uncoloured. `nvm alias default` emits ANSI escapes even when piped.
default_alias_target() {
  cat "$MACBOOT_NVM_DIR/alias/default" 2>/dev/null || true
}

install_nvm() {
  if [ -s "$MACBOOT_NVM_DIR/nvm.sh" ]; then
    skip "nvm -> $(nvm_read nvm --version || echo present) ($MACBOOT_NVM_DIR)"
    return 0
  fi

  # -f so a 404 page is not handed to bash. PROFILE=/dev/null stops the installer
  # appending its OWN nvm block to .zshrc: that copy is outside any macboot fence,
  # so ensure_block cannot see it and the machine ends up sourcing nvm twice.
  spin_start "installing nvm $NVM_VERSION"
  if ! run bash -c 'set -euo pipefail
    curl -fsSL --retry 3 "$1" |
      env HOME="$2" NVM_DIR="$3" PROFILE=/dev/null bash' \
    macboot-nvm "$NVM_INSTALLER_URL" "$MACBOOT_HOME" "$MACBOOT_NVM_DIR"; then
    spin_stop
    die "the nvm installer failed ($NVM_INSTALLER_URL). Everything below needs it,
     and a machine with no node breaks the Claude Code hooks this bootstrap
     installs. Check the network, or edit NVM_VERSION in scripts/40-node.sh."
  fi
  spin_stop
  ok_live "nvm $NVM_VERSION -> $MACBOOT_NVM_DIR"
}

# The interactive half: what makes `nvm use 20` work at a prompt, and deliberately
# the ONLY consumer of nvm.sh -- nothing non-interactive should have to source 1000+
# lines of shell to find a node binary.
profile_block() {
  # $HOME stays literal, expanded at shell start rather than now, so the block is
  # right for whoever's home this is. if/fi rather than `[ -s ... ] && . ...`: a
  # failing && test leaves $? non-zero as the last statement of .zshrc, and a
  # themed prompt then draws an error marker on the first prompt of every shell.
  ensure_block "$MACBOOT_HOME/.zshrc" nvm <<'EOF'
export NVM_DIR="$HOME/.nvm"
if [ -s "$NVM_DIR/nvm.sh" ]; then . "$NVM_DIR/nvm.sh"; fi
if [ -s "$NVM_DIR/bash_completion" ]; then . "$NVM_DIR/bash_completion"; fi
EOF
}

install_node_lts() {
  # The guard asks "is the default the SELF-ADVANCING lts/* alias?", not "does any
  # default resolve?". The old `[ -n "$(default_bin_dir)" ]` answered the second, so on
  # a machine whose default was pinned to a concrete version the module printed
  # "already the nvm default" and never advanced it -- measured on the source machine,
  # where alias/default held the literal string `20` (-> v20.20.2) while lts/* resolved
  # to v24.16.0 AND v24.16.0 was already installed. The module reported success for a
  # state it had never established, and the Claude Code hooks that requirement 1 exists
  # for got node 20 through the symlinks written two steps later.
  if [ "$(default_alias_target)" = 'lts/*' ] && [ -n "$(default_bin_dir)" ]; then
    skip "node -> default is lts/* ($(nvm_read nvm version default || echo unresolved))"
    return 0
  fi
  # Say why a re-run is doing work, so a pinned default does not look like a bug.
  if [ -n "$(default_alias_target)" ]; then
    log "nvm default is '$(default_alias_target)', not lts/* -- repointing it so future
     'nvm install --lts' runs move it forward on their own"
  fi
  if [ ! -s "$MACBOOT_NVM_DIR/nvm.sh" ]; then
    log "would run: nvm install --lts && nvm alias default 'lts/*' (once nvm exists)"
    return 0
  fi

  # `default -> lts/*`, not a concrete version: a later `nvm install --lts` then
  # moves the default forward by itself. The symlinks below still name a concrete
  # directory, so re-run this module after a node upgrade to re-point them.
  spin_start "nvm install --lts (downloads a node tarball)"
  if ! run bash -c 'set -eu
    export NVM_DIR="$1" HOME="$2"
    . "$NVM_DIR/nvm.sh"
    nvm install --lts
    nvm alias default "lts/*"' \
    macboot-nvm-node "$MACBOOT_NVM_DIR" "$MACBOOT_HOME"; then
    spin_stop
    die "nvm install --lts failed; no node was installed, so the symlink step
     below would link nothing and the verification would fail confusingly"
  fi
  spin_stop
  ok_live "node LTS installed, alias default -> lts/*"
}

expose_noninteractive() {
  # Measured on the source machine, and the reason this fence exists: in a clean
  # environment ~/.local/bin is NOT on PATH -- `env -i /bin/zsh -c 'echo $PATH'`
  # gives zsh's compiled-in default plus whatever .zshenv adds -- so the symlinks
  # alone stay invisible to exactly the shells this module exists to fix. .zshenv is
  # the one startup file EVERY zsh reads. For login shells /etc/zprofile's
  # path_helper then moves the entry to the end of PATH; it keeps it, which is all
  # `command -v` needs, and 00-path.zsh's interactive prepend is what still puts
  # ~/.local/bin ahead of /usr/bin's python3 at a prompt. The case guard is what
  # stops PATH growing one copy per nested shell.
  ensure_block "$MACBOOT_HOME/.zshenv" node-path <<'EOF'
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
EOF

  bin="$(default_bin_dir)"
  if [ -z "$bin" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      log "would link node, npm and npx from the nvm default into $LOCAL_BIN"
      return 0
    fi
    warn "no resolvable nvm default: nothing linked into $LOCAL_BIN, so
     non-interactive shells still have no node"
    return 0
  fi

  # npm and npx inside a node version's bin/ are themselves relative symlinks into
  # ../lib/node_modules/npm. Linking a symlink resolves fine and npm still finds
  # its own lib by realpath; copying the files instead would break it.
  for b in node npm npx; do
    if [ -x "$bin/$b" ]; then
      link_once "$bin/$b" "$LOCAL_BIN/$b"
    else
      warn "$b is not in $bin, so $LOCAL_BIN/$b was left alone"
    fi
  done
}

verify_clean_env() {
  if [ "$DRY_RUN" = "1" ]; then
    log "would verify in a CLEAN environment, not this shell:"
    log "    env -i HOME=\$HOME /bin/zsh  -c 'command -v node'   # hooks, daemons"
    log "    env -i HOME=\$HOME /bin/zsh -lc 'command -v node'   # login, non-interactive"
    return 0
  fi

  # env -i is the whole point. This process already has ~/.local/bin and an nvm
  # bin in PATH, so a plain `zsh -c 'node -v'` inherits them and prints a version
  # even when the arrangement is completely broken -- that false pass is how this
  # requirement gets ticked off while hooks keep failing.
  missing=''
  for b in node npm npx; do
    env -i HOME="$MACBOOT_HOME" /bin/zsh -c "command -v $b" >/dev/null 2>&1 ||
      missing="$missing $b"
  done

  if [ -z "$missing" ]; then
    ok "clean non-interactive zsh finds node, npm and npx"
    return 0
  fi

  # Two different failures, two different fixes, so do not report them as one.
  if env -i HOME="$MACBOOT_HOME" /bin/zsh -lc 'command -v node' >/dev/null 2>&1; then
    warn "a LOGIN shell finds node but a plain non-interactive one does not
     (missing:$missing), so it is coming from .zprofile/.zshrc rather than from
     ~/.local/bin -- hooks and LaunchAgents get neither. Check the
     macboot:node-path fence in $MACBOOT_HOME/.zshenv."
  else
    warn "no node in a clean environment (missing:$missing): every Claude Code
     hook, LaunchAgent and cron job here will fail to find it. Check
     'readlink $LOCAL_BIN/node' and the node-path fence in $MACBOOT_HOME/.zshenv"
  fi
}

# ---------------------------------------------------------------------------

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
  done

  require_macos
  step "nvm $NVM_VERSION"
  install_nvm
  profile_block
  step "node LTS"
  install_node_lts
  step "node for non-interactive shells (hooks, LaunchAgents, cron)"
  expose_noninteractive
  step "verify in a clean environment"
  verify_clean_env
  summary "node"
}

main "$@"
