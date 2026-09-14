#!/usr/bin/env bash
# 30-python.sh -- uv, and deliberately nothing else that manages a Python.
#
# Why no conda: every library in the stack this was written for ships an arm64 or
# universal2 wheel, so conda's one genuinely unique capability -- shipping non-Python
# dependencies (MKL, CUDA, GDAL) as conda packages -- buys nothing on this hardware. What
# it does buy is a base env prepended to PATH from .zshrc, which is how a project ends up
# resolving `python` against several hundred packages nobody declared.
#
# This module does not *remove* an existing miniconda, and the reason is narrower than it
# used to be. The blocker is not "projects need conda" -- a PEP-621 project with a
# requires-python does not care. It is that any .venv ALREADY BUILT from conda's
# interpreter has `bin/python` symlinked into the conda prefix, so deleting the prefix
# breaks the venv. Recreating those (`rm -rf .venv && uv sync`) is the actual migration,
# and it is per project rather than a program of work. Sequenced outside this repo either
# way: a bootstrap has no business deleting an interpreter someone's venvs point at.
#
# The --default flag on the install below is what stops the problem recurring: it is what
# makes a fresh `uv sync` pick uv's own interpreter instead of whatever leads PATH.
#
# Why no pyenv: it builds interpreters from source (minutes, and a compiler-flag
# hunt on every macOS upgrade) and then holds a second opinion about which python
# is "the" python. uv already downloads prebuilt CPythons and pins one per project,
# so pyenv's shims would only add a way for the two to disagree.
set -euo pipefail
# The path is computed, so plain `shellcheck` emits SC1091 (an info that still
# makes the exit status non-zero); `-x` resolves it via source=, the disable keeps
# the un-flagged invocation clean, and bash aborts here anyway if the file is gone.
# shellcheck source=lib/common.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

#: The vendor's own installer. Homebrew is NOT an option here: brew's uv would put
#: its interpreters under a prefix brew also upgrades, and `brew upgrade python`
#: would then move a python out from under a project uv had pinned.
UV_INSTALLER_URL="https://astral.sh/uv/install.sh"

#: Where the installer puts uv. Its default is $XDG_BIN_HOME, falling back to
#: ~/.local/bin -- passed explicitly so the answer does not depend on whether the
#: invoking shell happens to export XDG_BIN_HOME.
UV_BIN_DIR="$MACBOOT_HOME/.local/bin"

#: A pinned MINOR, not "3" and not "latest". `uv python install 3` follows the
#: newest release, so the same bootstrap run six months apart would hand two
#: machines different interpreters and no uv.lock in the owner's repos was
#: resolved against the second one.
MACBOOT_PYTHON="3.13"

usage() {
  cat <<'EOF'
Usage: 30-python.sh [--dry-run]

Installs uv (vendor installer, ~/.local/bin) and one pinned CPython via
`uv python install`. Creates no project venvs -- those are per-project and
per-lockfile, so they are printed as guidance instead.

EOF
}

# ---------------------------------------------------------------------------

# ok_live <msg> -- ok(), but silent in a dry run. run() returns 0 there without
# doing anything, so an unconditional ok() afterwards reports "installed" about a
# machine nothing touched, and a dry-run transcript has to read as true.
ok_live() { [ "$DRY_RUN" = "1" ] || ok "$*"; }

# uv_path -- the uv we should drive, or empty. PATH first, then UV_BIN_DIR:
# immediately after the installer runs, ~/.local/bin is not yet on this process's
# PATH (20-shell.sh only fixes future shells), so `has uv` is false for a uv that
# very much exists. Read-only, hence no run().
uv_path() {
  if has uv; then
    command -v uv
  elif [ -x "$UV_BIN_DIR/uv" ]; then
    printf '%s\n' "$UV_BIN_DIR/uv"
  fi
}

install_uv() {
  found="$(uv_path)"
  if [ -n "$found" ]; then
    # Version via the binary we found, not `uv`: reporting a version from a
    # different uv than the one this module will drive is worse than silence.
    skip "uv -> $("$found" --version 2>/dev/null || echo present) ($found)"
    return 0
  fi

  # -f matters more than it looks: without it curl writes the server's 404 page to
  # stdout and exits 0, so `sh` cheerfully interprets HTML. pipefail is set above,
  # which is what makes the curl half of the pipe able to fail the run at all.
  #
  # INSTALLER_NO_MODIFY_PATH: the installer would otherwise append its own PATH
  # line to .zshrc/.zshenv, next to the one shell/conf.d/00-path.zsh already
  # assembles. Two writers, one PATH, and the duplicate reappears on every re-run
  # because it is outside any macboot fence.
  # The single quotes are deliberate: $1/$2/$3 are the INNER bash's positional parameters,
  # supplied as the arguments after the script. shellcheck could follow that while the
  # command read `run bash -c ...`, because `bash` was then the first word it saw; with a
  # label in between it can no longer tell, so the intent is stated instead.
  # shellcheck disable=SC2016
  if ! run_quiet "the uv installer" bash -c 'set -euo pipefail
    curl -fsSL --retry 3 "$1" |
      env HOME="$2" UV_INSTALL_DIR="$3" INSTALLER_NO_MODIFY_PATH=1 sh' \
    macboot-uv "$UV_INSTALLER_URL" "$MACBOOT_HOME" "$UV_BIN_DIR"; then
    die "the uv installer failed. uv is the only Python manager this bootstrap
     installs, so nothing later can paper over it. Its output is above. Then:
       curl -fsSL $UV_INSTALLER_URL | less    # read it before running it"
  fi

  if [ "$DRY_RUN" = "1" ]; then
    return 0
  fi
  [ -x "$UV_BIN_DIR/uv" ] ||
    die "the uv installer reported success but $UV_BIN_DIR/uv is not executable"
  ok "uv -> $("$UV_BIN_DIR/uv" --version 2>/dev/null || echo installed)"
}

install_python() {
  uv="$(uv_path)"
  if [ -z "$uv" ]; then
    # The dry-run path on a fresh machine: uv does not exist yet, so there is
    # nothing to interrogate. Say what would happen rather than inventing state.
    log "would run: uv python install --default $MACBOOT_PYTHON (once uv exists)"
    return 0
  fi

  # HOME is overridden on every uv call, read and write alike. The interpreters
  # land in ~/.local/share/uv/python, so a scratch-home test that installed into
  # the scratch dir but *checked* the real home would report changed on every run.
  #
  # --managed-python, not bare --only-installed. `--only-installed` lists SYSTEM
  # interpreters too: on the machine this was written for it reported Homebrew's 3.14,
  # miniconda's 3.12 and /usr/bin's 3.9.6, none of which uv manages. With
  # MACBOOT_PYTHON matching any of those, the module printed "already managed by uv"
  # and its one job silently did not happen. Not a corner case either --
  # `brew deps pre-commit` pulls python@3.14 and 10-brew.sh runs before this module.
  #
  # The match is anchored and dot-terminated: unanchored, MACBOOT_PYTHON=3.1 (a
  # plausible typo for 3.10) matched cpython-3.14, 3.12 and 3.11 alike.
  #
  # In a DRY RUN the cache is redirected to a throwaway directory. `uv python list` is
  # a read-only question, but it populates $HOME/.cache/uv/interpreter-v4 as a side
  # effect of discovery -- 16 files, caught by tests/dry-run-purity.sh -- and a dry run
  # that writes into the user's home has changed something. In a live run those entries
  # belong in the user's own cache, so it is not redirected there.
  if [ "$DRY_RUN" = "1" ]; then
    _uv_probe_cache="$(mktemp -d "${TMPDIR:-/tmp}/macboot-uvprobe.XXXXXX")"
    _uv_listed="$(env HOME="$MACBOOT_HOME" UV_CACHE_DIR="$_uv_probe_cache" \
      "$uv" python list --managed-python --only-installed 2>/dev/null || true)"
    rm -rf "$_uv_probe_cache"
  else
    _uv_listed="$(env HOME="$MACBOOT_HOME" \
      "$uv" python list --managed-python --only-installed 2>/dev/null || true)"
  fi
  if printf '%s\n' "$_uv_listed" | grep -q "^cpython-$MACBOOT_PYTHON\."; then
    skip "CPython $MACBOOT_PYTHON -> already installed and managed by uv"
    return 0
  fi

  # --default is what makes this repo's "uv owns Python" claim true rather than aspirational.
  #
  # Without it uv installs only a VERSIONED shim (python3.13), so the bare `python3` name is
  # left to whatever else is on PATH -- and on any machine that ran this Brewfile that is
  # brew's python@3.14, which nobody chose: it arrives as a transitive dependency of
  # pre-commit, ollama and autojump (`brew deps pre-commit` lists python@3.14). So the
  # module installed a uv interpreter and then let an accident win, while README.md claimed
  # "uv. No pyenv, no conda, no bare venv".
  #
  # With --default uv also writes unversioned `python`/`python3` into ~/.local/bin, which
  # 00-path.zsh puts FIRST, ahead of both brew and any conda prepend. Measured on the
  # audited machine: uv already placed ~/.local/bin/python3.11 there itself, so this is uv's
  # own mechanism rather than something invented here. Plain flag on uv 0.11.16, no --preview.
  #
  # It also fixes a subtler thing: a conda-first PATH made `uv sync` build project venvs
  # against conda's interpreter (seen in the wild -- a pyvenv.cfg reading `uv = 0.11.16`
  # with `home = .../miniconda/base/bin`). Putting uv's own python first stops that.
  #
  # --preview-features python-install-default acknowledges what uv itself says: on uv
  # 0.11.16 `--default` prints "The `--default` option is experimental and may change
  # without warning". Passing the feature flag is uv's documented way to say "yes, I know",
  # and it silences a line that is a note to macboot's author, not to macboot's user.
  # If uv ever promotes the flag this becomes a no-op; if uv ever removes it, the install
  # fails loudly here rather than quietly reverting to a versioned-only shim.
  #
  # One opaque ~30 MB download and unpack, so run_quiet: uv draws its own progress meter,
  # and two writers on one line is what produced
  #   "| uv python install --default 3.13Installed Python 3.13.13 in 4.05s"
  # when a spinner was redrawing underneath it.
  if ! run_quiet "uv python install $MACBOOT_PYTHON" \
    env HOME="$MACBOOT_HOME" "$uv" python install --default \
    --preview-features python-install-default "$MACBOOT_PYTHON"; then
    # Not fatal: uv itself is installed and every project can still pin its own
    # interpreter on first `uv sync`. Only the pre-warmed default is missing.
    warn "uv could not install CPython $MACBOOT_PYTHON. uv is fine; the first
     'uv sync' in any project will fetch an interpreter itself."
    return 0
  fi
  ok_live "CPython $MACBOOT_PYTHON installed under uv's control (python, python3, python$MACBOOT_PYTHON)"
}

# Guidance, not action. A bootstrap that pre-creates venvs guesses wrong twice:
# it picks a directory layout the projects do not use, and it produces a venv
# resolved against no lockfile, which the first `uv sync` throws away anyway.
guidance() {
  log "per project, not here:"
  log "    uv venv                     # .venv in the project, never a global env"
  log "    uv pip install -e '.[dev]'  # or: uv sync, if it has a pyproject+lock"
  log "    git add uv.lock             # commit it: the lock is the reproducibility"
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
  step "uv (vendor installer, not Homebrew)"
  install_uv
  step "CPython $MACBOOT_PYTHON via uv"
  install_python
  guidance
  summary "python"
}

main "$@"
