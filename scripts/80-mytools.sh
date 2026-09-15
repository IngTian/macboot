#!/usr/bin/env bash
# 80-mytools.sh -- four projects of the author's, RECOMMENDED and never installed.
#
# This module used to clone all four from source into ~/src and build them. It does not
# any more, and the reasons are worth keeping, because "helpfully install it for you" is
# the obvious thing to reach for:
#
#   * ~/src was invented. Not a convention, not a place the author's own machine uses
#     (the real checkouts live under ~/devpro/), created by macboot and by nothing else.
#     Cloning there hands you a SECOND checkout of a project you may already have, in a
#     directory you did not choose. The same defect as the `includeIf gitdir:~/work/`
#     block that came out of git/gitconfig.
#   * The builds produced things that did not work. witness is the clear case: the module
#     deliberately avoided `make install` because it fetches a ~448 MB embedding model and
#     rewires Claude Code's hooks -- correct instinct for a bootstrap -- but embeddings ARE
#     witness, so what got linked was a binary that fails the project's own `witness
#     doctor`. A bootstrap should not leave behind something that looks installed and is not.
#   * Every one of these ships its own install path, and each is better than macboot's:
#     witness has an idempotent ./install.sh and signed darwin-arm64 release binaries,
#     manifold builds with plain swiftc and no Xcode, daylogs is a uv project. Re-implementing
#     four installers, none of them well, is not a bootstrap's job.
#
# So: this prints what they are and where they live. You decide. Nothing is fetched,
# nothing is built, nothing is written -- this module reports changed=0 forever, like
# 99-apps, and for the same reason.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: 80-mytools.sh [--dry-run]

Prints four of the author's projects and their repositories. Installs nothing, clones
nothing, asks nothing. --dry-run is accepted and changes no behaviour, because there is
no behaviour to suppress.
EOF
}

# ---------------------------------------------------------------------------

# One "name<TAB>lang<TAB>visibility<TAB>blurb" row each. A heredoc rather than a .tsv
# beside apps.tsv: four rows that change when a project is renamed do not need a data
# file, and a reader looking for what this module says should find it here.
tools_table() {
  cat <<'EOF'
witness	Go	public	a dated history of how you think and work, from your AI sessions
daylogs	Python	public	weight, food and spending in the terminal, typed by hand
manifold	Swift	public	a macOS screensaver: a mountain as breathing points of light
trading-desk	Python	private	the book in SQLite, the bets beside it, the rules as data
EOF
}

report_tools() {
  local name lang vis blurb width
  width=13

  printf '    %-*s %-7s %s\n' "$width" 'PROJECT' 'LANG' 'WHAT IT IS' >&2
  # Tab-delimited read, so the blurb may contain spaces and stays the last field.
  while IFS="$(printf '\t')" read -r name lang vis blurb; do
    [ -n "$name" ] || continue
    if [ "$vis" = private ]; then
      printf '  %s%s %-*s %-7s %s%s\n' \
        "$_C_DIM" "$_G_SKIP" "$width" "$name" "$lang" "$blurb (private)" "$_C_RESET" >&2
    else
      printf '  %s%s%s %-*s %-7s %s\n' \
        "$_C_BLUE" "$_G_ARROW" "$_C_RESET" "$width" "$name" "$lang" "$blurb" >&2
    fi
  done <<EOF
$(tools_table)
EOF
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

  step "my own tools (a recommendation, not an install)"
  report_tools

  log "All at https://github.com/IngTian. macboot installs none of them: each repo has"
  log "its own instructions, better than anything here could do for you. A star if one"
  log "turns out useful; otherwise nothing on this screen needs doing."

  summary "mytools"
}

main "$@"
