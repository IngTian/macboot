#!/usr/bin/env bash
# tests/dry-run-purity.sh -- prove that `bootstrap.sh --dry-run` is inert.
#
# The load-bearing assertion is on the FILESYSTEM, not on the transcript. Grepping
# a dry run for "rm" proves nothing in either direction: a correct dry run PRINTS
# `would rm -f ...` (so the grep fires on healthy output), and a module that wrote
# a file via a redirect instead of run() prints nothing at all (so the grep stays
# quiet on the one bug that matters). So: point MACBOOT_HOME at an empty scratch
# directory, plan the whole run, and assert the directory is still empty.
#
# The transcript checks that follow are tripwires, not the proof: they catch a
# module that echoes a command it then executes, and one that plans a write against
# the real $HOME instead of $MACBOOT_HOME.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

#: Where the scratch home is created. Defaults to TMPDIR so a run cannot dirty the
#: checkout; override to keep the evidence somewhere you can look at it.
MACBOOT_TEST_TMP="${MACBOOT_TEST_TMP:-${TMPDIR:-/tmp}}"

# This test reads and writes nothing outside its own mktemp directory, so it calls
# no run(). DRY_RUN is pinned off for its own bookkeeping: inheriting DRY_RUN=1
# must not turn the purity gate into a no-op that still prints a green summary.
# The bootstrap child is invoked with --dry-run explicitly, every time, regardless.
DRY_RUN=0

FAIL_N=0
_fail() {
  FAIL_N=$((FAIL_N + 1))
  warn "$*"
}

SCRATCH="$(mktemp -d "$MACBOOT_TEST_TMP/macboot-purity.XXXXXX")"
FAKE_HOME="$SCRATCH/home"
TRANSCRIPT="$SCRATCH/transcript.txt" # stderr: all narration
STDOUT_FILE="$SCRATCH/stdout.txt"    # stdout: the machine-readable channel
mkdir -p "$FAKE_HOME"
# Chained rather than replaced: common.sh installs `trap spin_stop EXIT`, and
# replacing it leaves a spinner process alive on any early exit. The scratch tree
# is kept on failure -- the leaked files are the evidence.
_cleanup() {
  spin_stop
  [ "$FAIL_N" -gt 0 ] || rm -rf "$SCRATCH"
}
trap _cleanup EXIT

# ---------------------------------------------------------------------------

step "plan a full dry run into an empty scratch home"

# --keep-going: purity has to be judged across every module, not up to the first
# one that dies. The exit status is asserted separately below, so a failure is
# still a failure -- it just does not blind the rest of the sweep.
#
# HOME is deliberately NOT redirected. Nothing executes in a dry run, so there is
# nothing to contain, and leaving the real HOME in place is what makes the last
# check possible: any planned write naming the real home is a module that reached
# for $HOME instead of $MACBOOT_HOME.
# STDERR is the transcript; stdout is kept aside. This repo splits the two streams on
# purpose -- every narration line from log/ok/warn/skip/run goes to stderr, and stdout
# is the machine-readable channel -- and folding them together broke the bare-command
# check below on 99-apps.sh, whose entire job is to print paste-ready
# `brew install --cask <token>` lines to stdout so that
# `99-apps.sh > install-missing.sh` yields a runnable file. On any machine missing a
# listed GUI app -- i.e. every CI runner, where VS Code, iTerm2, Claude Code, Obsidian
# and Raycast are all absent -- this test failed on arrival, flagging the module's
# documented output as a leaked mutation. The purity question is about the narration,
# so the transcript is the narration.
_rc=0
spin_start "bootstrap.sh --dry-run"
MACBOOT_HOME="$FAKE_HOME" DRY_RUN=1 NO_COLOR=1 \
  bash "$MACBOOT_ROOT/bootstrap.sh" --dry-run --keep-going \
  >"$STDOUT_FILE" 2>"$TRANSCRIPT" || _rc=$?
spin_stop

if [ "$_rc" = 0 ]; then
  ok "dry run exited 0 ($(wc -l <"$TRANSCRIPT" | tr -d ' ') transcript lines)"
else
  _fail "dry run exited $_rc; a --dry-run that cannot complete is not verifiable"
  tail -3 "$TRANSCRIPT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------

step "assert the scratch home is untouched"

# The whole test, in one command. -mindepth 1 so the directory itself does not
# count. Anything at all here means some module bypassed run(): a redirect, a
# `git config --global`, an installer that ignores DRY_RUN.
_LEAKS="$(find "$FAKE_HOME" -mindepth 1 2>/dev/null | LC_ALL=C sort)"
if [ -z "$_LEAKS" ]; then
  ok "scratch home still empty: $FAKE_HOME"
else
  _fail "dry run wrote $(printf '%s\n' "$_LEAKS" | wc -l | tr -d ' ') path(s) into the scratch home:"
  printf '%s\n' "$_LEAKS" | sed 's/^/      /' >&2
fi

# The checkout is the other place a stray write lands, and .gitignore already
# names both shapes: link_once's `<name>.bak.<stamp>` and ensure_block's
# `<file>.macboot.<pid>` temp. In a dry run neither may exist.
_DIRT="$(find "$MACBOOT_ROOT" -name .git -prune -o \
  \( -name '*.bak.*' -o -name '*.macboot.[0-9]*' \) -print 2>/dev/null | LC_ALL=C sort)"
if [ -z "$_DIRT" ]; then
  ok "no backup or temp files created inside the checkout"
else
  _fail "dry run left files in the checkout:"
  printf '%s\n' "$_DIRT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------

step "assert every planned mutation carries the would marker"

# run() prints "<dim> would<reset> <cmd>", so with NO_COLOR=1 a planned mutation is
# a line whose first word is `would`. A line whose first word is a mutating verb
# instead is a command that was echoed by hand -- which is how a module ends up
# executing something the plan claims it only described.
#
# The 0-2 leading spaces matter: log/ok/warn all prefix a glyph, and their
# multi-line bodies are indented 5 spaces, so prose that happens to start with
# "git push ..." cannot trip this. Only a column-0-ish bare command can.
_VERBS='rm|rmdir|mv|cp|ln|mkdir|touch|chmod|chown|chflags|ditto|tee'
_VERBS="$_VERBS|defaults|plutil|scutil|systemsetup|killall|launchctl|dscl|pkgutil"
_VERBS="$_VERBS|brew|installer|softwareupdate|xcode-select|chsh|sudo|mas|open|osascript"
_VERBS="$_VERBS|curl|wget|npm|nvm|node|rustup|cargo|uv|pip|pip3|gem|claude|ollama"

_WOULD="$(grep -c '^[[:space:]]*would ' "$TRANSCRIPT" || true)"
# Lines ending in "..." are spin_start's non-TTY fallback, whose label is usually
# the command it is about to wrap ("uv python install 3.13 ..."). Measured: that
# form is 1 of the 2 shapes this pattern would otherwise flag on a healthy run,
# and a real echoed command does not end in an ellipsis.
_BARE="$(grep -nE "^[[:space:]]{0,2}(sudo[[:space:]]+)?(/[A-Za-z0-9_.-]+)*/?($_VERBS)([[:space:]]|$)" \
  "$TRANSCRIPT" | grep -vE '\.\.\.[[:space:]]*$' || true)"

if [ -n "$_BARE" ]; then
  _fail "transcript lines that look like executed commands rather than plans:"
  printf '%s\n' "$_BARE" | sed 's/^/      /' >&2
else
  ok "no bare mutating command echoed outside the would marker"
fi

# A plan with zero `would` lines is not a pure dry run, it is a dry run that
# planned nothing -- an empty transcript would otherwise pass every check above
# and this test would certify a bootstrap that does nothing.
if [ "$_WOULD" -gt 0 ]; then
  ok "$_WOULD planned mutations, all marked"
else
  _fail "the plan contains zero 'would' lines: either every module is a no-op or
     --dry-run never reached run(). Nothing above proves anything in that state."
fi

# The stream split is itself an assertion. Excluding stdout from the checks above is
# only sound while stdout carries no narration: a module that printed run()'s output
# to stdout would move its planned mutations out of the transcript and quietly out of
# every check in this file.
_STRAY="$(grep -cE '^[[:space:]]*would ' "$STDOUT_FILE" || true)"
if [ "$_STRAY" = 0 ]; then
  ok "stdout carries no narration, so excluding it from the checks above is sound"
else
  _fail "$_STRAY 'would' line(s) went to STDOUT, not stderr. Narration on the
     machine-readable channel escapes the purity checks above and corrupts
     \`99-apps.sh > install-missing.sh\`."
fi

# ---------------------------------------------------------------------------

step "assert no planned mutation targets the real home"

# MACBOOT_HOME was redirected; $HOME was not. A `would` line whose ARGUMENTS name
# the real home is a module that hardcoded $HOME, and on the double-run test -- or
# on a curious owner's machine -- that line stops being hypothetical.
#
# Three things are stripped before the grep, each because it produced a real false
# positive on the first run of this test:
#   * the scratch home, which mktemp can legitimately place under $HOME (TMPDIR);
#   * MACBOOT_ROOT, because the checkout normally lives under $HOME, so every
#     honest `would ln -s <checkout>/shell/rc.zsh ...` contains the home path;
#   * the command word, plus any `env VAR=val` prefix. `would env HOME=... \
#     /Users/you/.local/bin/uv python install` names the real home as the TOOL it
#     runs, which is correct; only the arguments say where a write lands.
if [ "$FAKE_HOME" = "$HOME" ]; then
  skip "MACBOOT_HOME equals \$HOME; the two are indistinguishable here"
else
  _ESCAPED="$(grep '^[[:space:]]*would ' "$TRANSCRIPT" |
    sed -e "s|$FAKE_HOME|<home>|g" -e "s|$MACBOOT_ROOT|<checkout>|g" |
    sed -E 's/^[[:space:]]*would +//; s/^(env +([A-Za-z_][A-Za-z0-9_]*=[^ ]+ +)*)?[^ ]+ +//' |
    grep -F "$HOME/" || true)"
  if [ -z "$_ESCAPED" ]; then
    ok "every planned write stays inside \$MACBOOT_HOME or a system prefix"
  else
    _fail "planned mutations name the real \$HOME while MACBOOT_HOME was redirected:"
    printf '%s\n' "$_ESCAPED" | sed 's/^/      /' >&2
  fi
fi

# ---------------------------------------------------------------------------

[ "$FAIL_N" -gt 0 ] && log "evidence kept in $SCRATCH"
summary "dry-run purity"
[ "$FAIL_N" -eq 0 ] || die "$FAIL_N purity assertion(s) failed"
