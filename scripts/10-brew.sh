#!/usr/bin/env bash
# 10-brew.sh -- Homebrew itself, then the must-have formulae.
#
# Two measurements shape this module.
#
# 1. It never upgrades. `brew upgrade` on a half-configured machine is not
#    bootstrapping; it is how a bootstrap breaks something that was already fine.
#    That is enforced by HOMEBREW_NO_INSTALL_UPGRADE below rather than by merely
#    not typing `brew upgrade`, because `brew install <outdated>` upgrades too.
#
# 2. It installs formula by formula instead of handing the file to `brew bundle
#    install`, because `brew bundle` cannot distinguish "absent" from "outdated"
#    and its remedy for both is an upgrade. Measured on the source machine
#    (Homebrew 7.0.1): `brew bundle check --file=Brewfile` calls 12 of the 18
#    must-haves unsatisfied while only 7 are actually absent -- gh, fzf, tmux,
#    htop and gnupg are installed and merely behind. `brew bundle install` would
#    have upgraded all five. So `check` is used only as the fast all-satisfied
#    path, and `brew list` decides what is genuinely missing.
set -euo pipefail
# SC1091 disabled alongside the source= directive: the path is computed, so plain
# `shellcheck` cannot follow it and emits an info that still fails the exit
# status. `shellcheck -x` follows it properly and reports the same clean result.
# shellcheck source=lib/common.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

#: 1 = also install Brewfile.optional. Set by --optional, or from the environment
#: so `make optional` and bootstrap.sh (which passes no arguments) can both ask.
MACBOOT_OPTIONAL="${MACBOOT_OPTIONAL:-0}"

#: Pinning HEAD rather than a tag is Homebrew's own documented one-liner; a tag
#: would go stale and 404 on exactly the fresh machine this has to work on.
BREW_INSTALLER_URL="${BREW_INSTALLER_URL:-https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh}"

# Homebrew's environment, exported for this run only so nothing leaks into the
# user's profile:
#   NO_AUTO_UPDATE   an install that first spends a minute updating taps is
#                    indistinguishable from one that has hung.
#   NO_INSTALL_UPGRADE            see rule 1 -- without it every re-run can
#                    silently upgrade whatever has fallen behind since.
#   NO_INSTALLED_DEPENDENTS_CHECK otherwise installing one formula pulls every
#                    dependent of its dependencies into an upgrade as well.
#   NO_ENV_HINTS     the hints are advice for humans and noise in a transcript.
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_UPGRADE=1
export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1
export HOMEBREW_NO_ENV_HINTS=1

usage() {
  cat <<'EOF'
Usage: 10-brew.sh [--dry-run] [--optional]

Installs Homebrew if absent, adds its shellenv line to ~/.zprofile, then
installs the formulae in Brewfile that are missing. Never upgrades anything.
--optional (or MACBOOT_OPTIONAL=1) additionally installs Brewfile.optional.
EOF
}

# ---------------------------------------------------------------------------

# The installer needs sudo and, without help, blocks on a password prompt. When
# stdin is not a terminal that prompt is invisible and unanswerable, so the run
# hangs until someone notices -- print the two commands instead.
install_homebrew() {
  # bh_-prefixed for the reason spelled out above bundle(): common.sh helpers
  # assign their parameters as globals, so short names like `tmp` and `file` are
  # not safe to hold across a helper call.
  bh_prefix="$(brew_prefix)"
  if has brew || [ -x "$bh_prefix/bin/brew" ]; then
    skip "Homebrew present at $bh_prefix"
    # Put it on PATH for THIS process if it is not already. Returning without doing
    # this was the module's worst bug: main()'s `if ! has brew` then warned "Homebrew
    # is not on PATH yet; the formula phases are skipped", called summary(), and
    # returned 0 -- so bootstrap.sh wrote the 10-brew.done marker, not one must-have
    # formula was installed, and a plain re-run answered "done earlier".
    # An exit code of 0 for "I installed nothing" is the worst shape a bootstrap
    # failure can take, because it is indistinguishable from success.
    #
    # Two ordinary triggers, neither exotic: a user who follows this module's own
    # remediation text (install Homebrew by hand, then re-run 10-brew.sh in the SAME
    # terminal -- .zprofile is only read by a new login shell), and any run from a
    # hook, LaunchAgent or make with a sanitised PATH.
    if ! has brew && [ -x "$bh_prefix/bin/brew" ]; then
      eval "$("$bh_prefix/bin/brew" shellenv)"
      log "put $bh_prefix/bin on PATH for this run (it was installed but not exported)"
    fi
    return 0
  fi

  # A dry run installs nothing, so it needs no sudo and must not be able to fail on
  # its absence. Without this guard `./bootstrap.sh --dry-run </dev/null`, CI, and
  # `make test` all died here on precisely the machine class macboot targets -- a
  # fresh Mac without Homebrew -- which made the documented "dry-run first" workflow
  # unavailable exactly where it matters most.
  if [ "$DRY_RUN" = "1" ]; then
    log "would install Homebrew at $bh_prefix (needs sudo; not checked in a dry run)"
    return 0
  fi

  # -n means "fail rather than prompt", so this asks "is a credential already
  # cached?" without being able to hang.
  if [ ! -t 0 ] && ! sudo -n true 2>/dev/null; then
    log "Homebrew is missing and stdin is not a terminal, so its sudo prompt"
    log "cannot be answered. Run these two lines in a terminal, then re-run:"
    log "    /bin/bash -c \"\$(curl -fsSL $BREW_INSTALLER_URL)\""
    # `bash <path>`, not the bare path: every file in scripts/ ships mode 0644 and
    # only bootstrap.sh is 0755, so pasting the bare path returns "permission denied".
    log "    bash $MACBOOT_ROOT/scripts/10-brew.sh"
    die "cannot install Homebrew non-interactively (no cached sudo credential)"
  fi

  # Downloaded to a file and then executed, never `curl | bash`: bash executes
  # what it has already read, so a connection that dies mid-transfer leaves a
  # half-run installer. As a file, a truncated download is a curl error instead.
  # %/ strips the trailing slash macOS puts on TMPDIR, which otherwise shows up
  # as a doubled slash in the transcript and reads like a path-joining bug.
  bh_tmpdir="${TMPDIR:-/tmp}"
  bh_tmp="${bh_tmpdir%/}/macboot-brew-install.$$.sh"
  run curl -fsSL -o "$bh_tmp" "$BREW_INSTALLER_URL"

  # NONINTERACTIVE is NOT passed, and no spinner runs. Both were wrong for the
  # primary case -- a fresh Mac, a real terminal, an admin user, no cached sudo:
  #
  #   * In Homebrew's install.sh, NONINTERACTIVE makes have_sudo_access() run
  #     `sudo -n -l mkdir` instead of `sudo -v`, then abort with "Need sudo access on
  #     macOS (e.g. the user X needs to be an Administrator)!". So instead of one
  #     password prompt the run died, accusing an admin user of not being an admin.
  #     install.sh already sets NONINTERACTIVE itself when stdin is not a tty or CI is
  #     set, so passing it explicitly bought nothing and broke the interactive path.
  #   * A spinner redraws over stderr every 0.1s, which paints over the installer's
  #     own sudo prompt. The user sees an eternally spinning line and no question.
  #
  # The installer is verbose enough on its own; a long silent phase is not the risk
  # here, an invisible prompt is.
  log "running the Homebrew installer (a few minutes; it will ask for your password)"
  if ! run /bin/bash "$bh_tmp"; then
    run rm -f "$bh_tmp"
    die "the Homebrew installer failed; its own output is above"
  fi
  run rm -f "$bh_tmp"

  # The installer does not touch this shell's PATH, so without this every later
  # phase in this process still sees no brew and reports nothing to do.
  if [ "$DRY_RUN" != "1" ] && [ -x "$bh_prefix/bin/brew" ]; then
    eval "$("$bh_prefix/bin/brew" shellenv)"
  fi
  # Same rule as the end of bundle(): a dry run must not claim an install.
  if [ "$DRY_RUN" = "1" ]; then
    log "Homebrew would be installed at $bh_prefix"
  else
    ok "Homebrew installed at $bh_prefix"
  fi
}

# .zprofile, not .zshrc: zsh reads .zshrc only for interactive shells, so a
# LaunchAgent or a git hook would get a PATH without Homebrew on it. The prefix
# is resolved by brew_prefix (/opt/homebrew on Apple Silicon, /usr/local on
# Intel) because a hardcoded one silently breaks the other arch.
ensure_shellenv() {
  bh_prefix="$(brew_prefix)"
  # The -x guard keeps a profile that outlives Homebrew from erroring on every
  # new shell, which is how a bad PATH line turns into an unusable terminal.
  # Unquoted heredoc so the prefix is baked in, with \$( escaped so the eval is
  # evaluated by the future shell and not by this one.
  ensure_block "$MACBOOT_HOME/.zprofile" brew-shellenv <<EOF
if [ -x "$bh_prefix/bin/brew" ]; then
  eval "\$("$bh_prefix/bin/brew" shellenv)"
fi
EOF
}

# ---------------------------------------------------------------------------

# formulae_in <file> -- the names on `brew "x"` lines, in file order. Trailing
# comments are stripped by taking only what is inside the quotes.
#
# BOTH quote styles are matched. A Brewfile is Ruby, so `brew 'wget'` is as valid as
# `brew "wget"` and `brew bundle` installs either -- but a double-quote-only regex
# skipped the single-quoted ones, and if a single-quoted formula was the only missing
# one this function returned nothing, bundle() computed "none missing" and printed an
# all-green skip while never installing a must-have. Forever, because the fast path
# `brew bundle check` kept failing on every subsequent run too.
#
# Options after the name (`brew "x", args: [...]`, `link: false`) are still dropped:
# they are not part of the name, and the only use of this list is presence-checking.
#
# This function prints and nothing else. It is called in a command substitution,
# and a subshell cannot report anything back except its output: an earlier version
# also warned about cask lines from in here, and the warning appeared on stderr
# while summary() still said "0 warnings", because MACBOOT_WARNED was incremented
# in the subshell and thrown away with it. Anything that counts has to run in the
# caller, which is why warn_on_casks is separate.
formulae_in() {
  sed -n \
    -e 's/^[[:space:]]*brew[[:space:]]*"\([^"]*\)".*/\1/p' \
    -e "s/^[[:space:]]*brew[[:space:]]*'\([^']*\)'.*/\1/p" \
    "$1"
}

# Cask lines are reported and never installed (spec D8: GUI apps are listed, never
# installed). Silence here would let one edit reintroduce the authentication
# dialogs that make an unattended run impossible, and reinstall an app the user
# already dragged in from a .dmg.
warn_on_casks() {
  if grep -q '^[[:space:]]*cask[[:space:]]' "$1" 2>/dev/null; then
    warn "$(basename "$1") contains cask lines; ignoring them (spec D8)"
  fi
}

# _count <space-or-newline-separated list> -- how many items. The lists here are
# strings rather than arrays because under `set -u` bash 3.2 aborts on "${arr[@]}"
# when the array is empty, which is exactly the "nothing missing" case. tr strips
# the leading padding wc(1) prints on macOS.
_count() { printf '%s' "$1" | wc -w | tr -d ' '; }

# bundle <label> <file> <fatal>
#
# fatal=1 for the must-haves (the toolchain everything downstream assumes),
# fatal=0 for Brewfile.optional, where one renamed formula must not end the run.
# Failures are collected and reported once at the end rather than aborting on the
# first: a bootstrap that tells you about one broken formula per invocation
# wastes an afternoon.
#
# Every local is bf_-prefixed because the helpers in common.sh assign their
# parameters as globals -- progress() does `label="${3:-}"` with no `local`, so a
# caller that stores its own state in `label` has it silently rewritten from
# inside the loop. Measured: the closing line printed "pre-commit -> 7 installed"
# instead of "must-have -> 7 installed" before this rename.
bundle() {
  bf_label="$1"
  bf_file="$2"
  bf_fatal="$3"

  if [ ! -f "$bf_file" ]; then
    [ "$bf_fatal" = 1 ] && die "$bf_file is missing (incomplete checkout?)"
    warn "$bf_label: $(basename "$bf_file") is missing; nothing to do"
    return 0
  fi

  # A satisfied file is the common case on a re-run, and this is the cheapest way
  # to prove it (measured 0.9s). Any other outcome -- unsatisfied, or a Homebrew
  # too old to have `bundle` built in -- falls through to the path below, which
  # needs no bundle subcommand at all.
  #
  # NOT in a dry run. `brew bundle` is Ruby and it materialises the signed JSON API
  # payload plus a bootsnap cache into $HOME/Library/Caches/Homebrew: measured 904 paths
  # and ~37 MB against a fresh HOME, plus one network fetch. `--dry-run` promises to write
  # nothing, "not to any cache", and this is the same class of bug as the ssh probe that
  # used to create ~/.ssh/known_hosts -- a read-only-looking question with a write side
  # effect. The `brew list` path below answers the same question and measured 0 leftover
  # paths, so a dry run simply takes it and reports "N present, none missing" instead.
  if [ "$DRY_RUN" != "1" ] && brew bundle check --file="$bf_file" >/dev/null 2>&1; then
    skip "$bf_label -> all formulae satisfied"
    return 0
  fi

  warn_on_casks "$bf_file"
  bf_wanted="$(formulae_in "$bf_file")"
  [ -n "$bf_wanted" ] || {
    warn "$bf_label: no brew lines found in $(basename "$bf_file")"
    return 0
  }

  # One `brew list` for the whole file: measured 0.04s, against roughly a second
  # per formula for `brew list <name>` run once per name in the file.
  bf_installed="$(brew list --formula -1)" ||
    die "brew list failed; the Homebrew install at $(brew_prefix) is broken"

  bf_missing=''
  for bf_name in $bf_wanted; do
    # -F because a formula name is a literal, and -x so `go` cannot match
    # `gopls`, which would leave a must-have silently uninstalled.
    printf '%s\n' "$bf_installed" | grep -qxF "$bf_name" ||
      bf_missing="$bf_missing $bf_name"
  done

  bf_total="$(_count "$bf_wanted")"
  bf_n="$(_count "$bf_missing")"
  if [ "$bf_n" = 0 ]; then
    # The `brew bundle check` disagreement from the header comment: every formula
    # is present, some are merely behind. Upgrading them is not this script's job,
    # so this reports skip, and so does the next run.
    skip "$bf_label -> $bf_total present, none missing (some are outdated; not upgrading)"
    return 0
  fi

  log "$bf_label: $bf_n of $bf_total missing"
  bf_done=0
  bf_failed=''
  for bf_name in $bf_missing; do
    # --formula so a name that is also a cask token can never resolve to the GUI
    # app. Brew's own output stays visible: when a build fails, the log path it
    # prints is the only thing that helps.
    run brew install --formula "$bf_name" || bf_failed="$bf_failed $bf_name"
    bf_done=$((bf_done + 1))
    # Drawn after each install so the bar lands below brew's own output instead
    # of being overwritten by it. Suppressed for a single formula, where a 100%
    # bar says less than the line above it.
    [ "$bf_n" -gt 1 ] && progress "$bf_done" "$bf_n" "$bf_name"
  done

  if [ -n "$bf_failed" ]; then
    [ "$bf_fatal" = 1 ] && die "must-have formulae failed to install:$bf_failed"
    warn "$bf_label: optional formulae failed, continuing:$bf_failed"
    return 0
  fi
  # Not "installed" in a dry run: run() already printed one `would` line each,
  # and a summary claiming an install that did not happen is the exact thing
  # --dry-run exists to rule out.
  if [ "$DRY_RUN" = "1" ]; then
    log "$bf_label -> $bf_n would be installed"
  else
    ok "$bf_label -> $bf_n installed"
  fi
}

# ollama ships as a must-have, but NO model is pulled. The runner is ~30 MB; each
# model is 0.3-3 GB, and which ones you want is a personal call, so pulling any would
# be the bootstrap spending your disk on a guess. A hint costs nothing and a 2 GB
# download nobody asked for is the kind of thing that makes people distrust a
# bootstrap. `ollama list` is the check, not `ollama --version`: the binary always
# exists once brew installed it, so the interesting question is whether any weights
# are present.
ollama_hint() {
  has ollama || return 0
  if [ "$DRY_RUN" = "1" ]; then
    return 0
  fi
  # `ollama list` prints a header row even when empty, and it needs no server for
  # that. -le 1 means "header only", i.e. no models.
  if [ "$(ollama list 2>/dev/null | grep -c .)" -le 1 ]; then
    log "ollama is installed with no models (deliberate). To pull a small one:"
    log "    ollama pull llama3.2:3b      # ~2 GB"
  fi
}

# ---------------------------------------------------------------------------

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --optional) MACBOOT_OPTIONAL=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
  done

  require_macos

  step "Homebrew"
  install_homebrew
  ensure_shellenv

  # In a dry run on a machine without Homebrew there is no `brew` to ask, and
  # inventing an answer would make the transcript fiction. Say so and stop.
  #
  # In a LIVE run, reaching this point means install_homebrew claimed success (or
  # found an existing install) and there is still no brew on PATH. That is a failure,
  # and it must exit non-zero: returning 0 let bootstrap.sh record 10-brew as done
  # while nothing had been installed, and the next run then skipped the module
  # entirely. "I installed nothing" and "everything was already present" must never
  # share an exit code.
  if ! has brew; then
    if [ "$DRY_RUN" = "1" ]; then
      warn "Homebrew is not installed, so the formula phases cannot be previewed"
      summary "brew"
      return 0
    fi
    summary "brew"
    die "Homebrew is still not on PATH after the install phase, so no formula was
     installed. Open a NEW terminal (so .zprofile runs) and re-run:
         bash $MACBOOT_ROOT/scripts/10-brew.sh"
  fi

  step "must-have formulae"
  bundle "must-have" "$MACBOOT_ROOT/Brewfile" 1

  if [ "$MACBOOT_OPTIONAL" = "1" ]; then
    step "optional formulae"
    bundle "optional" "$MACBOOT_ROOT/Brewfile.optional" 0
  else
    skip "optional formulae -> not requested (--optional or MACBOOT_OPTIONAL=1)"
  fi

  ollama_hint
  summary "brew"
}

main "$@"
