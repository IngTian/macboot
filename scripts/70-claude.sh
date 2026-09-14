#!/usr/bin/env bash
# 70-claude.sh -- the Claude Code layer: a sanitised settings.json, an empty
# memory directory, and exactly one plugin.
#
# "Sanitised" is load-bearing. claude/settings.json in this repo is a skeleton:
# permission lists plus one hook, no absolute paths, no hostnames, nothing that
# names an employer or a project. Shipping the author's real ~/.claude/settings.json
# would publish his client list and directory layout in a public repo, so the file
# here is written from scratch rather than exported.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

CLAUDE_DIR="$MACBOOT_HOME/.claude"
SETTINGS_SRC="$MACBOOT_ROOT/claude/settings.json"

#: One marketplace, one plugin.
#:
#: `ponytail` is deliberately absent and must not be added back: it is deferred to
#: v2 pending evaluation on the owner's machine (spec, "Claude Code layer"). A
#: public bootstrap should not install a plugin nobody has yet lived with for a
#: month. `adversarial-audit` cannot be here at all -- it installs from a
#: local-directory marketplace with no git remote, so a fresh machine has nothing
#: to fetch.
MARKETPLACE='anthropics/claude-plugins-official'
PLUGIN='superpowers@claude-plugins-official'

usage() {
  cat <<'EOF'
Usage: 70-claude.sh [--dry-run]

Links claude/settings.json to ~/.claude/settings.json (backing up an existing
real file once), creates ~/.claude/memory empty, and installs the superpowers
plugin if it is not already installed.

Needs the `claude` CLI only for the plugin step; without it the module warns and
prints the two commands instead of failing.
EOF
}

# ---------------------------------------------------------------------------

# A malformed settings.json is not inert: Claude Code refuses to start rather than
# ignoring it, so shipping one would break the tool this module exists to configure.
# Checked BEFORE anything is moved or backed up, and only when jq is available (it is
# in the Brewfile, but 70-claude can be run standalone on a bare machine).
validate_settings() {
  if ! has jq; then
    warn "jq is not installed, so settings.json could not be validated as JSON.
     Run 10-brew.sh first if you want that check."
    return 0
  fi
  render_settings | jq -e . >/dev/null 2>&1 ||
    die "$SETTINGS_SRC is not valid JSON after substitution.
     Reproduce with: sed 's|@MACBOOT_ROOT@|$MACBOOT_ROOT|g' $SETTINGS_SRC | jq ."
  ok "settings.json is valid JSON"
}

# render_settings -- the shipped settings.json with @MACBOOT_ROOT@ resolved.
#
# The hook command needs an absolute path to claude/hooks/shfmt-on-write.sh, and
# settings.json is a static file in a repo that can be cloned anywhere, so the path has
# to be substituted at install time. A placeholder rather than a relative path because
# hooks run with an unspecified working directory.
#
# `|` as the sed delimiter: the replacement is a filesystem path full of slashes.
render_settings() {
  sed "s|@MACBOOT_ROOT@|$MACBOOT_ROOT|g" "$SETTINGS_SRC"
}

install_settings() {
  local dst rendered
  [ -f "$SETTINGS_SRC" ] || die "missing $SETTINGS_SRC (incomplete checkout?)"
  dst="$CLAUDE_DIR/settings.json"

  # COPIED, not symlinked, and this is the important part.
  #
  # Claude Code writes to ~/.claude/settings.json itself -- persisting a theme, a
  # model, a global permission rule. With a symlink into this checkout, those writes
  # land in the WORKING TREE: `git status` goes dirty for reasons the user did not
  # cause, a later `git pull` refuses or conflicts, and machine-specific permission
  # entries sit inside a public repo one `git commit -a` away from publication. That
  # is precisely the leak this module's header says it exists to prevent, arranged by
  # the module itself.
  #
  # MEASURED, not assumed. Running this module twice against a scratch home and diffing
  # what Claude Code left behind: it reordered the JSON keys (moved "ask" after "deny")
  # and appended two blocks of its own --
  #
  #     "extraKnownMarketplaces": { "claude-plugins-official": { ... } },
  #     "enabledPlugins": { "superpowers@claude-plugins-official": true }
  #
  # -- written by the `claude plugin` calls this very module makes. Under the old
  # symlink those writes landed in the checkout, so installing superpowers dirtied a
  # public repo with local state. Hence the copy.
  #
  # And hence SEED-ONCE rather than re-render: the file is jointly owned by macboot,
  # Claude Code and the user, so rewriting it on every run would delete the plugin
  # registrations macboot itself just made, plus any theme or permission the user has
  # since granted. A content comparison cannot be idempotent against a file that a
  # later step of the same run modifies. macboot provides the starting point and then
  # gets out of the way; `git pull` never updates a live config, which is the honest
  # cost of not fighting the tool.
  rendered="$(render_settings)"

  if [ -f "$dst" ] && [ ! -L "$dst" ]; then
    skip "settings.json -> exists, left alone (yours and Claude Code's to edit now)"
  else
    # Only reachable when the destination is absent or is one of macboot's own old
    # symlinks, because the seed-once branch above catches every real file. So there is
    # nothing of the user's to back up here -- which is the point of seeding once: no
    # run after the first can ever move their settings aside.
    if [ -L "$dst" ]; then
      # An earlier macboot linked this into the checkout. Replacing our own link needs
      # no backup: the content is in git. This is also the migration path off that
      # design, so anyone who ran an older macboot stops writing into their checkout.
      run rm -f "$dst"
      log "settings.json -> replacing macboot's old symlink with a real file"
    fi
    if [ "$DRY_RUN" = "1" ]; then
      printf '%s would%s write %s\n' "$_C_DIM" "$_C_RESET" "$dst" >&2
    else
      run mkdir -p "$CLAUDE_DIR"
      printf '%s\n' "$rendered" >"$dst" ||
        die "cannot write $dst"
      MACBOOT_CHANGED=$((MACBOOT_CHANGED + 1))
      ok "settings.json -> written"
    fi
  fi

  # settings.local.json is intentionally never touched. It holds per-machine
  # answers (which directories are trusted, one-off allows) that are meaningless
  # on another machine and are exactly the kind of thing a public repo must not
  # carry.
  [ -f "$CLAUDE_DIR/settings.local.json" ] &&
    skip "settings.local.json -> left alone (machine-private by design)"
  return 0
}

ensure_memory_dir() {
  dir="$CLAUDE_DIR/memory"

  # Created EMPTY, always, and nothing in this repo can ever populate it. On the
  # source machine that directory holds a private archive pointer, compensation
  # figures and employer-contract strategy; `memory/` is in this repo's
  # .gitignore so a checkout placed near it cannot absorb it either.
  #
  # This is structural, not a rule anyone has to remember: the code that would
  # copy something in does not exist, so there is nothing to forget. If a future
  # module ever wants to seed memory, that is a new decision, not a fill-in.
  if [ -d "$dir" ]; then
    skip "memory dir -> $dir exists (contents untouched)"
    return 0
  fi
  run mkdir -p "$dir"
  ok "memory dir -> $dir created empty"
}

# plugin_state_has <state file> <literal json key>
#
# Reads ~/.claude/plugins/*.json instead of shelling out to `claude plugin list`.
# Two reasons, both concrete: a read bypasses run(), so calling the CLI here would
# execute during a --dry-run and break the promise that a dry run touches nothing
# observable; and the CLI has to boot to answer, where grep -F on a 2 KB state
# file is instant. The keys are literal strings in both files
# ("claude-plugins-official", "superpowers@claude-plugins-official"), so a fixed
# grep is exact rather than a guess about JSON shape.
plugin_state_has() {
  file="$CLAUDE_DIR/plugins/$1"
  [ -f "$file" ] || return 1
  grep -qF "\"$2\"" "$file"
}

install_plugins() {
  # `claude plugin` writes to the real $HOME/.claude regardless of MACBOOT_HOME.
  # In scratch-home mode (the double-run test, CI) running it would mutate the
  # tester's actual machine while the transcript claims a fake home -- so skip,
  # loudly enough that nobody reads the skip as "already installed".
  if [ "$CLAUDE_DIR" != "$HOME/.claude" ]; then
    skip "plugins -> skipped: MACBOOT_HOME is not \$HOME and 'claude plugin' would still write to $HOME/.claude"
    return 0
  fi

  if ! has claude; then
    # Claude Code is in apps.tsv: listed, never installed. Missing it is a warning,
    # never a die -- the settings link and the memory directory above are already
    # in place and are useful on their own.
    warn "the 'claude' CLI is not on PATH. Install Claude Code (see: make apps), then run:"
    log "    claude plugin marketplace add $MARKETPLACE"
    log "    claude plugin install $PLUGIN"
    return 0
  fi

  # known_marketplaces.json keys a marketplace by its repo name, not the full
  # owner/repo slug it was added with.
  if plugin_state_has known_marketplaces.json "${MARKETPLACE#*/}"; then
    skip "marketplace ${MARKETPLACE#*/} -> already added"
  elif run claude plugin marketplace add "$MARKETPLACE"; then
    ok "marketplace $MARKETPLACE"
  else
    warn "could not add the $MARKETPLACE marketplace; skipping the plugin"
    return 0
  fi

  if plugin_state_has installed_plugins.json "$PLUGIN"; then
    skip "plugin $PLUGIN -> already installed"
    return 0
  fi

  # One long opaque operation (clone plus install), so one spinner. spin_stop is
  # on both branches: an unstopped spinner survives the module and keeps drawing
  # over the next one's output.
  spin_start "installing $PLUGIN"
  if run claude plugin install "$PLUGIN"; then
    spin_stop
    ok "plugin $PLUGIN"
  else
    spin_stop
    warn "'claude plugin install $PLUGIN' failed; run it by hand to see the error"
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

  step "Claude Code settings"
  validate_settings
  install_settings

  step "Claude Code memory directory"
  ensure_memory_dir

  step "Claude Code plugins"
  install_plugins

  summary "claude"
}

main "$@"
