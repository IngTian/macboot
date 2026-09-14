#!/usr/bin/env bash
# 50-git.sh -- the shipped git config and the git identity.
#
# There is no `git config --global` call anywhere in this module on purpose: measured on
# git 2.54.0 (Apple Git-157), a --global write follows a symlinked ~/.config/git/config
# and rewrites the target in place, which here is a tracked file in a public repo. Every
# write below therefore names its destination with `git config --file`, which cannot
# wander.
#
# It does ASK, when there is a human to ask. A bootstrap that leaves the machine unable to
# commit has not finished -- `git commit` with no identity fails outright. The offer is
# interactive-only and falls back to what this module always did (print the commands,
# change nothing) on a non-tty run, under --yes, or in a dry run.
#
# GitHub access -- gh auth and the SSH key -- is scripts/55-github.sh, deliberately not
# here: `gh` is on tests/double-run.sh's forbidden list, so one `run gh` in this file made
# the whole module ineligible and silently removed it from the only idempotency test.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# No require_macos: this module writes only under $MACBOOT_HOME/.config and shells out to
# git, so there is nothing macOS-specific to refuse over. An earlier version of this comment
# credited "the Linux CI runner" -- all four CI jobs run on macos-latest and always have, so
# that was never the reason.

#: The identity shipped in git/gitconfig. Compared against the EFFECTIVE identity
#: rather than grepped out of the file, so it is still detected when it arrives
#: through an include or a leftover ~/.gitconfig.
GIT_PLACEHOLDER_NAME='PLACEHOLDER'
GIT_PLACEHOLDER_EMAIL='placeholder@example.invalid'

#: XDG paths, not ~/.gitconfig. Keeping the global config out of $HOME's top level
#: is what lets both files be symlinks into a checkout without a dotfile manager.
GIT_CONF_DIR="$MACBOOT_HOME/.config/git"

usage() {
  cat <<'EOF'
Usage: 50-git.sh [--dry-run]

Links git/gitconfig and git/gitignore to ~/.config/git/{config,ignore}, warns if a
real ~/.gitconfig would override them, then offers to set your git identity in
~/.config/git/config.local.

The offer is skipped, and the commands printed instead, whenever there is no terminal
to ask at or --yes was passed. No existing config file is ever edited.
GitHub access (gh auth, SSH key) is scripts/55-github.sh.
EOF
}

# ---------------------------------------------------------------------------

link_config() {
  # XDG_CONFIG_HOME, when exported, moves the file git actually reads. We still
  # link the documented default -- MACBOOT_HOME redirection is what the double-run
  # test needs -- and say so, because the failure mode otherwise is a config that
  # is linked, correct, and never read by anything.
  if [ -n "${XDG_CONFIG_HOME:-}" ] && [ "$XDG_CONFIG_HOME" != "$MACBOOT_HOME/.config" ]; then
    warn "XDG_CONFIG_HOME=$XDG_CONFIG_HOME, so git reads \$XDG_CONFIG_HOME/git/config.
     This module links $GIT_CONF_DIR/config, which git will then ignore. Link or
     copy the two files across by hand if you keep that variable set."
  fi

  link_once "$MACBOOT_ROOT/git/gitconfig" "$GIT_CONF_DIR/config"
  link_once "$MACBOOT_ROOT/git/gitignore" "$GIT_CONF_DIR/ignore"
}

# A pre-existing ~/.gitconfig is never touched. It is also not simply "in the
# way", and the accurate description matters because the two halves point in
# opposite directions (measured, git 2.54.0):
#
#   * A normal config read loads ~/.config/git/config FIRST and ~/.gitconfig
#     AFTER it. Last wins, so the old file overrides only the keys it actually
#     sets; everything else we ship still applies.
#   * `git config --global` is scoped to ~/.gitconfig ALONE once that file
#     exists -- `--global --get user.email` returned empty against a config
#     that plainly set it in the XDG file. So the XDG file becomes invisible to
#     exactly the command people use to inspect and edit "their global config".
#
# Hence: warn, print what we ship for comparison, and let the owner merge.
legacy_gitconfig() {
  local legacy
  legacy="$MACBOOT_HOME/.gitconfig"
  if [ ! -e "$legacy" ] && [ ! -L "$legacy" ]; then
    skip "no $legacy to merge"
    return 0
  fi

  warn "$legacy exists. Leaving it alone -- it is yours, and it may hold tokens or
     an insteadOf rewrite this bootstrap knows nothing about. Consequences: every
     key it sets overrides the config linked above, and \`git config --global\`
     from now on reads and writes only that file."
  log "Shipped settings, to merge into $legacy (or move them there and delete it):"
  # A read, so no run(). Comments and blanks dropped, so what is left is valid
  # config text and can be pasted straight in -- except the [user] section, which
  # is skipped deliberately: printing "name = PLACEHOLDER" under the heading
  # "settings to merge" invites someone to paste the placeholder identity into the
  # one file that overrides everything else.
  awk '/^\[/ { keep = ($0 !~ /^\[user\]/) }
       keep && NF && $0 !~ /^[[:space:]]*[#;]/ { print "     " $0 }' \
    "$MACBOOT_ROOT/git/gitconfig" >&2
}

# The identity check. Reading the EFFECTIVE values rather than the file, because
# the question is "what author will the next commit carry", and three of the ways
# to ask that give the wrong answer:
#
#   * From inside a repo, a repo-local user.email masks the global one, so the
#     check passes on a machine where nothing global is set.
#   * With a scope flag, include expansion is off by default: measured,
#     `--global --get user.name` returned PLACEHOLDER while
#     `--global --includes --get user.name` returned the real name from
#     config.local. A scoped read reports a placeholder that is not in effect.
#   * Against $HOME, the double-run test against a scratch MACBOOT_HOME would
#     read the real home's identity and report a pass that proves nothing.
#
# So: full read, from /, with HOME pinned to MACBOOT_HOME.
git_identity() {
  if ! has git; then
    warn "git is not on PATH, so the identity check cannot run. The Xcode CLT ships
     one and 00-preflight.sh requires the CLT, so this usually means PATH is broken."
    return 0
  fi

  local name email
  name="$(cd / && HOME="$MACBOOT_HOME" git config --get user.name 2>/dev/null || true)"
  email="$(cd / && HOME="$MACBOOT_HOME" git config --get user.email 2>/dev/null || true)"

  if [ -z "$name" ] || [ -z "$email" ]; then
    warn "no git identity in effect (name='$name' email='$email'). git refuses to
     commit at all in this state, with 'Please tell me who you are'."
    identity_howto
    return 0
  fi

  case "$name:$email" in
    "$GIT_PLACEHOLDER_NAME:"* | *":$GIT_PLACEHOLDER_EMAIL")
      warn "git identity is still the shipped placeholder: $name <$email>.
     Commits made now are misattributed, and fixing the author of commits you have
     already pushed means rewriting history and force-pushing it."
      identity_howto
      ;;
    *) ok "git identity in effect: $name <$email>" ;;
  esac
}

# ASKED, never derived. Deriving an identity from the machine -- the short user name, the
# full name in the user record, an address found in an existing config -- is how a
# hand-me-down laptop signs its new owner's commits with the old owner's name, and how a
# work address ends up on a personal repo. Only the human knows. But asking is not
# deriving, and a bootstrap that leaves the machine unable to commit at all has not
# finished: `git commit` fails outright with "Please tell me who you are".
#
# The write goes to config.local via `git config --file`, NOT `git config --global`.
# --global is scoped to whichever file git decides is global, and here that follows a
# symlink into the checkout: measured on git 2.54.0, it rewrites the tracked
# git/gitconfig in a public repo. --file names the destination and cannot wander.
identity_howto() {
  local name email

  # Interactive only, and never in a dry run. Everywhere else this stays what it always
  # was -- printed advice -- because writing a guessed name into a config file on an
  # unattended run is exactly the misattribution the paragraph above is about.
  if [ "$DRY_RUN" != "1" ] && [ "$MACBOOT_YES" != "1" ] && [ -t 0 ] &&
    ask "set your git identity now?" y; then
    printf '    name  (e.g. Ada Lovelace): ' >&2
    read -r name || name=''
    printf '    email (e.g. ada@example.com): ' >&2
    read -r email || email=''
    if [ -n "$name" ] && [ -n "$email" ]; then
      run git config --file "$GIT_CONF_DIR/config.local" user.name "$name"
      run git config --file "$GIT_CONF_DIR/config.local" user.email "$email"
      ok "git identity -> $name <$email> in config.local"
      return 0
    fi
    warn "name or email was empty, so nothing was written"
  fi

  log "Set it in config.local, which git/gitconfig includes and which is OUTSIDE"
  log "this checkout (the file is created for you by the first command):"
  log "    git config --file ~/.config/git/config.local user.name  \"Your Name\""
  log "    git config --file ~/.config/git/config.local user.email \"you@example.com\""
  log "Do NOT use \`git config --global\` for this: it follows the symlink and edits"
  log "$MACBOOT_ROOT/git/gitconfig, a tracked file in a public repo."
  pause_for "set the two lines above, or skip and do it later"
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

  [ -f "$MACBOOT_ROOT/git/gitconfig" ] && [ -f "$MACBOOT_ROOT/git/gitignore" ] ||
    die "git/gitconfig or git/gitignore is missing from $MACBOOT_ROOT.
     This checkout is incomplete; a partial clone would leave git with no global
     ignore, which is how .claude/settings.local.json ends up committed."

  step "git config"
  link_config
  legacy_gitconfig

  step "git identity"
  git_identity

  summary "git"
}

main "$@"
