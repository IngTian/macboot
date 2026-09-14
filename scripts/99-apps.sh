#!/usr/bin/env bash
# 99-apps.sh -- report which GUI apps are present and print the commands for the
# rest. INSTALLS NOTHING, ever.
#
# That is a decision, not a limitation (spec: "GUI apps -- listed, never
# installed"): an app is a licence, a login and a several-hundred-megabyte
# download, and `brew install --cask` against an app someone dragged in by hand
# aborts halfway with "It seems there is already an App at ...". So this module
# calls run() exactly zero times, which is also why it is safe to run at any
# moment -- including on a fully configured machine, where it is the fastest way
# to see what a reinstall would need.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

APPS_TSV="$MACBOOT_ROOT/apps.tsv"

#: `brew list --cask` takes about a second, so it is called ONCE and matched
#: against in memory. One call per row turned this module into a seven-second wait
#: for a table that has to feel instant.
BREW_CASKS=''

#: Column width for the app name. Widest row is "Visual Studio Code" (18).
NAME_W=20

#: A literal tab, because apps.tsv is tab-separated and a tab typed into a case
#: pattern or a ${var%%...} is invisible to the next person reading this file.
TAB="$(printf '\t')"

usage() {
  cat <<'EOF'
Usage: 99-apps.sh [--dry-run]

Reads apps.tsv, reports each app as installed or missing, and writes the
`brew install --cask` lines for the missing ones to STDOUT so they can be piped:

    bash scripts/99-apps.sh > install-missing.sh   # review, then run it

Installs nothing. --dry-run is accepted only so this module takes the same flags
as its siblings; it makes no difference, because there is nothing to dry-run.
EOF
}

# ---------------------------------------------------------------------------

# bundle_name <display name> -- the .app basename to look for, or empty when the
# app has no bundle. Deriving "<name>.app" from the display name is right for five
# of seven rows and WRONG for the others in a way that reports a running app as
# missing, so the exceptions are listed rather than guessed.
bundle_name() {
  case "$1" in
    iTerm2) printf 'iTerm.app' ;;            # ships as iTerm.app
    'Docker Desktop') printf 'Docker.app' ;; # ships as Docker.app
    'Claude Code') printf '' ;;              # a CLI: no bundle exists at all
    *) printf '%s.app' "$1" ;;
  esac
}

# cli_name <display name> -- the command that proves the app is installed, for the
# rows that are not .app bundles.
cli_name() {
  case "$1" in
    'Claude Code') printf 'claude' ;;
    *) printf '' ;;
  esac
}

# cask_token <install hint> -- the last word of "brew install --cask <token>".
# Empty hint (no cask exists) yields empty, and every caller treats that as "the
# note explains how".
cask_token() { printf '%s' "${1##* }"; }

# found_where <display name> <cask token> -- prints where it was found, or nothing.
# Order matters: the cask list is checked first because it is the answer that also
# tells you the app is managed by brew, and ~/Applications is checked because a
# per-user install is still installed.
found_where() {
  name="$1"
  token="$2"
  bundle="$(bundle_name "$name")"
  cli="$(cli_name "$name")"

  if [ -n "$token" ] && printf '%s\n' "$BREW_CASKS" | grep -qxF "$token"; then
    printf 'brew cask'
    return 0
  fi
  if [ -n "$bundle" ]; then
    if [ -d "/Applications/$bundle" ]; then
      printf '/Applications'
      return 0
    fi
    if [ -d "$MACBOOT_HOME/Applications/$bundle" ]; then
      # Spelled out rather than as "~/Applications": the home this ran against is
      # MACBOOT_HOME, which in a test is not the tilde the reader would assume.
      printf '%s/Applications' "$MACBOOT_HOME"
      return 0
    fi
  fi
  if [ -n "$cli" ] && has "$cli"; then
    printf 'PATH (%s)' "$cli"
    return 0
  fi
  return 1
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
  [ -f "$APPS_TSV" ] || die "no app list at $APPS_TSV (incomplete checkout?)"

  if has brew; then
    BREW_CASKS="$(brew list --cask 2>/dev/null || true)"
  else
    warn "brew is not on PATH yet, so detection is /Applications only and the
     commands below cannot run until 10-brew.sh has finished."
  fi

  # ONE filter, applied once, feeding both the count and the loop.
  #
  # They used to disagree: the count was an awk expression allowing whitespace before
  # `#`, while the loop recognised `#` only at column 0. A comment indented by a single
  # space was therefore excluded from the denominator AND processed as an app row --
  # reproduced with a scratch table: "2 of 2 missing" printed while three rows had been
  # examined, the bar hit 100% before the last row, and the comment text was emitted
  # into install-missing.sh as a command to run.
  #
  # Field count is validated here too, for the same reason it belongs in this pass: a
  # row rejected inside the main loop would desynchronise the denominator all over
  # again.
  valid_rows=''
  bad_n=0
  while IFS= read -r line || [ -n "$line" ]; do
    # Strip leading whitespace, then apply the comment/blank rule to the result. This
    # is now the ONLY definition of "is this a data row".
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in '' | \#*) continue ;; esac

    # Exactly three tabs => four fields. The likeliest way someone breaks this file is
    # an editor converting tabs to spaces, and the failure is nasty rather than loud:
    # every field becomes the whole line, so `cmd="$hint"` puts an English sentence
    # into the generated script (`Fake App nice brew install --cask fake A note` ->
    # `Fake: command not found`) and the table's column alignment collapses.
    tabs="$(printf '%s' "$line" | tr -dc "$TAB" | wc -c | tr -d ' ')"
    if [ "$tabs" != 3 ]; then
      bad_n=$((bad_n + 1))
      warn "apps.tsv line with $tabs tab(s), expected 3 -- skipped. Tabs converted to
     spaces by an editor? Row began: $(printf '%.48s' "$trimmed")"
      continue
    fi
    valid_rows="$valid_rows$line
"
  done <"$APPS_TSV"

  total="$(printf '%s' "$valid_rows" | grep -c . || true)"
  [ "$total" -gt 0 ] || die "$APPS_TSV has no usable app rows ($bad_n malformed)"

  # Rows are collected first and printed after the bar finishes: a redrawn
  # progress bar interleaved with table rows leaves a half-drawn bar wedged
  # between two lines of the table.
  rows=''
  missing_n=0
  missing_cmds=''
  # Split each line by hand instead of `IFS=<tab> read -r name tier hint note`.
  # Tab counts as IFS *whitespace* no matter what IFS is set to, so read collapses
  # two adjacent tabs into one delimiter: measured on a row with an empty
  # install_hint, the note slid into hint and the table offered the sentence
  # "No cask exists: download the .dmg" as a command to run. An empty column is
  # exactly the case apps.tsv documents, so it has to survive.
  #
  # A here-string, not a pipe: a piped `while` runs in a subshell and every variable
  # accumulated below would be discarded at the end of the loop. Comments, blanks and
  # malformed rows are already gone, so this loop has no filtering left to do -- which
  # is what keeps `total` and the iteration count in agreement by construction.
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    name="${line%%"$TAB"*}"
    rest="${line#*"$TAB"}"
    tier="${rest%%"$TAB"*}"
    rest="${rest#*"$TAB"}"
    hint="${rest%%"$TAB"*}"
    note="${rest#*"$TAB"}"

    token="$(cask_token "$hint")"
    if where="$(found_where "$name" "$token")"; then
      rows="$rows$(printf 'ok\t%s\t%s\t%s' "$name" "$tier" "$where")
"
      continue
    fi
    missing_n=$((missing_n + 1))
    if [ -n "$hint" ]; then
      cmd="$hint"
      where='MISSING -- see stdout'
    else
      # No cask exists. Emitting the note as if it were a command would produce a
      # generated script whose first line is an English sentence.
      cmd='# no cask exists for this one; install it by hand'
      where='MISSING -- no cask, see note'
    fi
    rows="$rows$(printf 'no\t%s\t%s\t%s' "$name" "$tier" "$where")
"
    missing_cmds="$missing_cmds$(printf '\n# %s (%s) -- %s\n%s' \
      "$name" "$tier" "$note" "$cmd")
"
  done <<EOF
$valid_rows
EOF

  # The table. Header is printed with four leading spaces so it lines up with the
  # glyph+space prefix that ok()/warn() emit; the glyphs themselves come from
  # common.sh, which already knows whether the locale can render them.
  printf '    %-*s %-5s %s\n' "$NAME_W" 'APP' 'TIER' 'STATUS' >&2
  # Safe to use read here, unlike the apps.tsv loop above: these four fields are
  # built two dozen lines up and none of them can be empty.
  while IFS="$TAB" read -r state name tier where; do
    [ -n "$state" ] || continue
    line="$(printf '%-*s %-5s %s' "$NAME_W" "$name" "$tier" "$where")"
    case "$state" in
      ok) ok "$line" ;;
      # warn(), not skip(): a missing app is something for you to decide about, and
      # the count it feeds into is echoed again by the closing summary, where it
      # will not have scrolled away.
      *) warn "$line" ;;
    esac
  done <<EOF
$rows
EOF

  if [ "$missing_n" = 0 ]; then
    log "all $total apps present. macboot installs none of them; this is a report."
  else
    log "$missing_n of $total missing. macboot NEVER installs GUI apps -- the commands"
    log "are on stdout, so you read them before anything downloads a gigabyte."
    # stdout, while every narration line above went to stderr. That split is what
    # makes `99-apps.sh > install-missing.sh` produce a runnable file instead of a
    # transcript with a progress bar in it.
    printf '#!/usr/bin/env bash\n'
    printf '# Missing GUI apps, from macboot apps.tsv. Review before running.\n'
    printf '%s\n' "$missing_cmds"
    # Stop here when there is someone to stop for. This is the one module whose entire
    # output is commands for the human, and it is the LAST module in the run -- so
    # carrying straight on means the list is the last thing printed and then immediately
    # buried under the closing screen. Inert on a non-tty, which is also the case where
    # stdout is a file being written for later.
    pause_for "$missing_n cask command(s) above are yours to run"
  fi

  summary "apps"
}

main "$@"
