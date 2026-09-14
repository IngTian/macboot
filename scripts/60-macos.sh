#!/usr/bin/env bash
# 60-macos.sh -- system defaults, all through defaults_set so an already
# configured machine reports skip instead of change.
#
# Scope rule: widely agreeable, and reversible by one click in System Settings.
# Nothing here disables a security feature. On an MDM-enrolled Mac the agent
# reverts some of these on its next check-in, so the module can report changed
# forever through no fault of its own -- 00-preflight.sh warns about enrollment.
#
# SAFETY NOTE for anyone testing this: defaults(1) talks to cfprefsd, which
# resolves the preference directory from the user record rather than from $HOME, so
# MACBOOT_HOME must not be assumed to sandbox this module the way it sandboxes
# 50-git.sh -- only the ~/Screenshots mkdir honours it. Exercise it with DRY_RUN=1.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# DO NOT ADD com.apple.symbolichotkeys HERE.
#
# Putting Raycast on Cmd-Space is spec requirement 2 and is deliberately manual:
# the setting is a nested dict under AppleSymbolicHotKeys keyed "64"/"65", which
# defaults(1) cannot address a single leaf of, and cfprefsd holds the domain in
# memory so the write succeeds and is then overwritten by the daemon's cached copy.
# A script that half-works here leaves the machine with no Cmd-Space launcher at
# all. It is written up, with the ordering trap, in notes/MANUAL-STEPS.md.

#: MACBOOT_CHANGED as it stood when this module started, so restart_ui can tell
#: "this module changed something" from "an earlier module in the same bootstrap
#: process did". Initialised here because restart_ui reads it under set -u.
_MACOS_CHANGED_AT_START=0

#: Where screenshots go. Kept out of the Desktop because a Desktop full of
#: Screenshot PNGs is also what Stage Manager and every screen share show.
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$MACBOOT_HOME/Screenshots}"

usage() {
  cat <<'EOF'
Usage: 60-macos.sh [--dry-run]

Applies keyboard, Finder, screenshot, Dock and trackpad defaults, then restarts
Finder/Dock/SystemUIServer if anything changed. Every write goes through
defaults_set, so a second run reports changed=0.
EOF
}

# ---------------------------------------------------------------------------
# The settings table: one "<domain> <key> <type> <value>" per line, value last so
# it may contain spaces. Comment lines and blanks are skipped by the reader, which
# is what lets the rationale live next to the setting it explains.
# ---------------------------------------------------------------------------
settings_table() {
  cat <<EOF
# Key repeat, in the ~15 ms units this key uses: 2 is ~30 ms between repeats and
# 15 is ~225 ms before the first. Both sit at the fast end of what the System
# Settings sliders can express, which is the reason to set them from a script.
NSGlobalDomain KeyRepeat -int 2
NSGlobalDomain InitialKeyRepeat -int 15

# Press-and-hold shows the accent-picker popup instead of repeating the key, so
# holding j in vim or k in less moves the cursor exactly once and then stops.
NSGlobalDomain ApplePressAndHoldEnabled -bool false

# Full extensions everywhere. Finder hiding ".app" is also what makes
# "invoice.pdf.app" look like a PDF.
NSGlobalDomain AppleShowAllExtensions -bool true

# Smart quotes turn a pasted shell snippet into one that fails with a syntax error
# you cannot see; smart dashes turn "--flag" into an en dash.
NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false
NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false
NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false
NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false

# The collapsed save panel has no path field and no sidebar, which is how a file
# ends up somewhere you then have to search for.
NSGlobalDomain NSNavPanelExpandedStateForSaveMode -bool true

# Tap to click. Two domains because the built-in trackpad and a paired Magic
# Trackpad are separate devices with separate preference domains. The twin that
# System Settings itself reads needs the -currentHost flag, which defaults_set has
# no parameter for -- see the note above main(). Note also that this heredoc is
# unquoted so $SCREENSHOT_DIR expands: backticks in these comments would be run as
# commands, which is why there are none.
com.apple.AppleMultitouchTrackpad Clicking -bool true
com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true

# Finder: know where you are. The POSIX path in the title bar is the difference
# between "Documents" and "iCloud Drive/Documents", which are different places.
com.apple.finder ShowPathbar -bool true
com.apple.finder ShowStatusBar -bool true
com.apple.finder _FXShowPosixPathInTitle -bool true

# List view (Nlsv) for folders Finder has no saved state for. The default icon
# view is the one view that cannot show a modification time.
com.apple.finder FXPreferredViewStyle -string Nlsv

# The "are you sure you want to change the extension" modal, which now appears on
# every rename because extensions are visible.
com.apple.finder FXEnableExtensionChangeWarning -bool false

# Search the current folder (SCcf), not This Mac: searching the whole disk from
# inside a project directory is almost never the question being asked.
com.apple.finder FXDefaultSearchScope -string SCcf

# No .DS_Store on network shares or USB volumes: on a shared drive these are what
# a colleague on Windows sees, and on a stick they travel back with the files.
# Local .DS_Store files stay -- Finder needs them for per-folder view state.
com.apple.desktopservices DSDontWriteNetworkStores -bool true
com.apple.desktopservices DSDontWriteUSBStores -bool true

# Screenshots: PNG, into their own folder. That folder must exist before this
# write means anything -- see ensure_screenshot_dir.
com.apple.screencapture location -string $SCREENSHOT_DIR
com.apple.screencapture type -string png

# The transparent drop shadow around a window capture makes every cropped or
# pasted window shot look misaligned, and pads the file for nothing.
com.apple.screencapture disable-shadow -bool true

# Dock out of the way, and out of the way immediately: the default reveal delay is
# what makes an autohidden Dock feel broken rather than hidden.
com.apple.dock autohide -bool true
com.apple.dock autohide-delay -float 0
com.apple.dock tilesize -int 48

# Recents sit in their own Dock section and reorder themselves, so the icon at a
# given position changes under the pointer.
com.apple.dock show-recents -bool false

# Stop Mission Control reordering Spaces by most-recent-use, which is what makes
# Ctrl-2 land on a different desktop depending on where you have just been.
com.apple.dock mru-spaces -bool false
EOF
}

# ---------------------------------------------------------------------------

# defaults write accepts a screenshot location that does not exist, and
# screencapture then quietly keeps writing to the Desktop -- the setting reads
# back correctly while nothing about the behaviour has changed. Create it first.
ensure_screenshot_dir() {
  if [ -d "$SCREENSHOT_DIR" ]; then
    skip "$SCREENSHOT_DIR -> exists"
    return 0
  fi
  run mkdir -p "$SCREENSHOT_DIR"
  ok "created $SCREENSHOT_DIR"
}

#: Per-setting output is held back until the bar is finished. progress() redraws
#: with a carriage return, so a line printed mid-loop lands on the bar's own row;
#: once that row is wider than the terminal it wraps and the next redraw overwrites
#: the wrapped fragment instead of the bar. Measured on a 27-setting table: bar row
#: 60 columns plus a status line of 50-90, i.e. garbled under ~110 columns. Holding
#: the lines also means an already-configured machine prints the bar and nothing
#: else, instead of 27 near-identical "already correct" lines.
_NL='
'

apply_settings() {
  local total done_n domain key type value item_log kept before_skipped already rows
  # ONE filter, applied once, feeding both the count and the loop.
  #
  # The comment here used to claim the two "can never desynchronise" because both came
  # from settings_table. They shared a GENERATOR but not a FILTER:
  # `grep -c '^[^#[:space:]]'` requires the domain in column 0, while the loop's
  # `read -r domain ...` strips leading whitespace, so a line indented by even one space
  # was counted zero times and executed once. Demonstrated on a copy outside the repo:
  # the bar closed one item early, the last setting was processed after the bar had
  # printed its final newline, the "N of M already correct" line was wrong, and on a TTY
  # the final call rendered 103%. No indented line exists today and .editorconfig does
  # not enforce column 0 inside a heredoc, so an editor auto-indent is the whole trigger
  # -- and a "can never" comment is exactly what stops the next author from checking.
  rows="$(settings_table | grep -vE '^[[:space:]]*(#|$)' || true)"
  total="$(printf '%s' "$rows" | grep -c . || true)"
  [ -n "$total" ] || total=0
  done_n=0
  kept=''
  already="$MACBOOT_SKIPPED"

  # Not created through run(): this is our own scratch buffer in TMPDIR, not a
  # change to the machine, and putting it through run() would both skip creating it
  # in dry-run (leaving nothing to read back) and inflate the changed counter that
  # the double-run test reads.
  item_log="${TMPDIR:-/tmp}/macboot-60-macos.$$"

  # Fed by process substitution, NOT a pipe: `settings_table | while read` puts the
  # loop body in a subshell, where defaults_set's increments to MACBOOT_CHANGED
  # happen and are then discarded on exit -- and that counter is the entire
  # idempotency claim.
  while read -r domain key type value; do
    # No filtering left to do: comments and blanks were removed by the same expression
    # that produced $total, which is what keeps the two in step by construction rather
    # than by assertion.
    [ -n "$domain" ] || continue
    before_skipped="$MACBOOT_SKIPPED"
    : >"$item_log"
    # On failure the buffer is flushed before dying: a swallowed error message is
    # worse than a wall of text, and defaults(1) is where a locked-down or
    # MDM-managed domain shows up.
    defaults_set "$domain" "$key" "$type" "$value" 2>"$item_log" || {
      cat "$item_log" >&2
      die "defaults write failed for $domain $key"
    }
    # A skip line says nothing a counter cannot; anything else (the write, or the
    # dry-run "would" line) is kept and printed once the bar is out of the way.
    if [ "$MACBOOT_SKIPPED" -eq "$before_skipped" ]; then
      kept="$kept$(cat "$item_log")$_NL"
    fi
    done_n=$((done_n + 1))
    progress "$done_n" "$total" "$key"
  done < <(printf '%s\n' "$rows")

  rm -f "$item_log"
  [ -n "$kept" ] && printf '%s' "$kept" >&2
  already=$((MACBOOT_SKIPPED - already))
  [ "$already" -gt 0 ] && log "$already of $total settings were already correct"
  return 0
}

# Last, and only if something actually changed. These processes own the plists we
# just wrote and rewrite them from memory when they exit, so without a restart
# some settings appear to apply and then revert; with one, Finder windows close,
# the Dock flashes and menu-bar extras reload. Doing that to a machine where every
# setting was already correct is the difference between "idempotent" and
# "harmless to re-run".
restart_ui() {
  local app changed_here
  changed_here=$((MACBOOT_CHANGED - _MACOS_CHANGED_AT_START))
  if [ "$DRY_RUN" != "1" ] && [ "$changed_here" -eq 0 ]; then
    skip "restart Finder/Dock/SystemUIServer -> nothing changed"
    return 0
  fi
  for app in Finder Dock SystemUIServer; do
    # killall exits non-zero on "No matching processes", which under set -e would
    # abort the run over a process that was not running anyway.
    pgrep -x "$app" >/dev/null 2>&1 || {
      skip "$app is not running"
      continue
    }
    # Not redirecting run's stderr here: that would also swallow its own
    # "would killall ..." line and make the dry-run transcript a lie.
    run killall "$app" || warn "could not restart $app; log out and back in to apply"
  done
}

# ---------------------------------------------------------------------------
# Left out on purpose, so nobody has to rediscover why:
#
#   * `defaults -currentHost write NSGlobalDomain com.apple.mouse.tapBehavior -int 1`
#     is the per-host twin of the two Clicking keys above, and the one the System
#     Settings checkbox reflects. defaults_set takes <domain> <key> <type> <value>
#     with no place for -currentHost, and hand-rolling the write would put a
#     mutation outside run(). Tap-to-click may therefore still need one click in
#     System Settings; requested as a helper change rather than bypassed here.
#   * com.apple.symbolichotkeys -- see the block at the top of this file.
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
  has defaults || die "defaults(1) not found on a Darwin system; refusing to guess"
  _MACOS_CHANGED_AT_START="$MACBOOT_CHANGED"

  step "screenshot folder"
  ensure_screenshot_dir

  step "macOS defaults"
  apply_settings

  step "restart affected UI processes"
  restart_ui

  summary "macos"
}

main "$@"
