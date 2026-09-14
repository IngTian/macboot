#!/usr/bin/env bash
# 55-github.sh -- finish GitHub access: authenticate this machine, and get an SSH key
# onto the account.
#
# Separate from 50-git.sh on purpose, and the reason is a test rather than taste. This
# module's one action is `gh auth login`, and `gh` is on tests/double-run.sh's forbidden
# list -- correctly, since it reaches the network and writes a credential. Leaving it
# inside 50-git.sh made that whole module ineligible, which silently dropped it from the
# only idempotency test in the suite (the run went from 4 modules to 3 and still printed
# green). Local config files and a network credential are two concerns; splitting them
# keeps 50-git.sh testable and makes this step separately runnable as `make module M=55`.
#
# It drives gh rather than reinventing it. From `gh auth login --help` (gh 2.94):
# specifying ssh as the git protocol "will detect existing SSH keys to upload, prompting
# to create and upload a new key if one is not found". So macboot runs no ssh-keygen and
# asks nobody to paste a public key into a browser: rolling our own would mean writing the
# upload too, which needs an admin:public_key token scope that gh already knows how to
# request, and it would put the token in a file we chose instead of the login keychain.
#
# Key CUSTODY is still unsolved and still manual -- see notes/MANUAL-STEPS.md. Creating a
# key was never the hard half; having a second copy of it is.
set -euo pipefail
# shellcheck source=lib/common.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# No require_macos: like 50-git.sh this touches nothing macOS-specific, so its dry run
# stays exercisable on a Linux CI runner.

usage() {
  cat <<'EOF'
Usage: 55-github.sh [--dry-run]

Offers to run `gh auth login --git-protocol ssh`, which authenticates this machine in
the browser and uploads an SSH key, creating an ed25519 one first if you have none.

Does nothing when gh is already authenticated. Prints the command instead of offering
it whenever there is no terminal to ask at, or under --yes: the browser flow needs a
human to approve it and a one-time code pasted back.
EOF
}

# ---------------------------------------------------------------------------

github_access() {
  if ! has gh; then
    warn "gh is not on PATH (it comes from 10-brew.sh), so GitHub access was not set up.
     Once brew has finished:  gh auth login --git-protocol ssh"
    return 0
  fi

  # The whole idempotency story: gh auth status exits 0 when a usable token exists, so a
  # second run is a skip and never re-authenticates.
  if gh auth status >/dev/null 2>&1; then
    skip "gh -> already authenticated"
    return 0
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log "would offer to run: gh auth login --git-protocol ssh"
    log "  (authenticates this machine, then uploads an SSH key, creating one if needed)"
    return 0
  fi

  # Guarded HERE rather than by ask()'s default. ask() answers with its default on a
  # non-tty, and the useful default for this question is yes -- but `gh auth login` needs
  # a browser AND a terminal to paste a one-time code into, so answering yes into a pipe
  # would launch an interactive flow nobody can complete.
  if [ ! -t 0 ] || [ "$MACBOOT_YES" = "1" ]; then
    warn "GitHub access is not set up, and 'gh auth login' needs a browser and a
     terminal. Run this yourself when you are sitting at the machine:
         gh auth login --git-protocol ssh"
    return 0
  fi

  log "GitHub access is not set up. gh does all of it in one browser flow:"
  log "  - authenticates this machine (the token goes to your login keychain)"
  log "  - uploads an SSH key, creating an ed25519 one first if you have none"
  log "You approve it in the browser and paste back the one-time code it shows you."
  if ! ask "run 'gh auth login' now?" y; then
    log "Skipped. When you want it:  gh auth login --git-protocol ssh"
    pause_for "or run the line above in another window now"
    return 0
  fi

  if run gh auth login --git-protocol ssh; then
    ok "gh -> authenticated; git will use ssh for github.com"
  else
    # gh writes its token only on success, so a half-finished flow leaves nothing behind
    # and re-running is safe.
    warn "'gh auth login' did not complete, and nothing was half-written. Re-run it
     yourself when ready:  gh auth login --git-protocol ssh"
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

  step "GitHub access"
  github_access

  summary "github"
}

main "$@"
