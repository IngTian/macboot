#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# macboot — entrypoint. A logging loop over scripts/[0-9][0-9]-*.sh with no
# module-specific knowledge in it: modules are discovered by glob, so adding
# scripts/45-foo.sh needs no edit here. A hand-maintained list is how a module
# ends up silently never running, and how run order drifts from the filenames.
#
# Modules are invoked as child processes rather than sourced. A sourced module's
# `exit 1` would kill bootstrap before the summary, and its variables would leak
# into every later module. The cost is that MACBOOT_CHANGED lives in the child, so
# each module reports its counters and its warnings back through a scratch FILE
# ($_TALLY below) that finish() totals. A file and not a pipe: piping a module's
# output would cost it the tty, and with it the colour.
# Before that, bootstrap's closing line counted only what bootstrap itself wrote
# and cheerfully printed "0 warnings" after five warnings had scrolled past.

# --no-color has to be honoured before it can be parsed: common.sh picks the
# colour codes when it is sourced, which is line 4. Re-exec once with NO_COLOR in
# the environment instead of reaching into its private _C_* variables, which a
# later helper would silently outgrow. "$@" is still intact here.
for _arg in "$@"; do
  [ "$_arg" = "--no-color" ] || continue
  [ -n "${MACBOOT_RECOLORED:-}" ] && break
  export NO_COLOR=1 MACBOOT_RECOLORED=1
  exec bash "$0" "$@"
done

usage() {
  cat <<'EOF'
usage: ./bootstrap.sh [options]

  --dry-run        print every mutation as "would <command>" and change nothing
  --only <module>  run only this module (repeatable; overrides its phase marker)
  --skip <module>  do not run this module (repeatable)
  --optional       also install the nice-to-have tier (Brewfile.optional)
  --mytools        yes to all of my own tools without asking per tool
  --restart        clear phase markers, so every module runs again
  --keep-going     do not stop at the first failing module; still exits non-zero
  --no-color       plain output (same as NO_COLOR=1 in the environment)
  --yes            never stop to ask: skip the confirmation, and take the
                   documented default for every question a module would ask.
                   Every default is the conservative one, so an unattended run
                   acquires nothing it was not told to. Required when stdin is
                   not a tty.
  --help           this text

<module> is any of the four names a module answers to: 40-node.sh, 40-node,
node, or 40. An argument matching no module is an error, not a silent no-op.

Modules that finish leave a marker in ~/.macboot/state, so an interrupted run
resumes instead of redoing an hour of downloads. A plain re-run after a clean
run therefore reports every module as done; use --restart (or --only) to make
one execute again. Nothing is marked during a dry run.

Environment passed to every module: DRY_RUN, NO_COLOR, MACBOOT_ROOT,
MACBOOT_HOME, MACBOOT_STAMP, MACBOOT_YES, MACBOOT_OPTIONAL, MACBOOT_MYTOOLS,
MACBOOT_STEP_TOTAL, MACBOOT_STEP_N.
EOF
}

DO_RESTART=0
KEEP_GOING=0
MACBOOT_YES="${MACBOOT_YES:-0}"
MACBOOT_OPTIONAL="${MACBOOT_OPTIONAL:-0}"
MACBOOT_MYTOOLS="${MACBOOT_MYTOOLS:-0}"
# Space-delimited strings, not arrays: under `set -u`, bash 3.2 aborts on
# "${arr[@]}" when the array is empty, which is the common case for both.
ONLY=''
SKIP=''

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --only)
      [ $# -ge 2 ] || die "--only needs a module name"
      ONLY="$ONLY $2"
      shift
      ;;
    --skip)
      [ $# -ge 2 ] || die "--skip needs a module name"
      SKIP="$SKIP $2"
      shift
      ;;
    --optional) MACBOOT_OPTIONAL=1 ;;
    --mytools) MACBOOT_MYTOOLS=1 ;;
    --restart) DO_RESTART=1 ;;
    --keep-going) KEEP_GOING=1 ;;
    --no-color) NO_COLOR=1 ;;
    --yes | -y) MACBOOT_YES=1 ;;
    --help | -h)
      usage
      exit 0
      ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

require_macos

# Children re-source common.sh and would otherwise each choose their own defaults.
# An unexported DRY_RUN turns --dry-run into a live install; an unexported
# MACBOOT_STAMP gives every module a different backup suffix, so one run's .bak
# files scatter across timestamps instead of sorting together.
export DRY_RUN NO_COLOR MACBOOT_ROOT MACBOOT_HOME MACBOOT_STAMP
export MACBOOT_YES MACBOOT_OPTIONAL MACBOOT_MYTOOLS

STATE_DIR="$MACBOOT_HOME/.macboot/state"

# When the run started, for the one line of progress information worth printing after the
# fact. A first `make all` is minutes of Homebrew; a re-run is seconds. Being told which of
# those just happened is the difference between "it worked" and "did it do anything?"
_RUN_STARTED_AT=$(date +%s)

# Where children report their counters and their warnings. Passed per invocation below
# rather than exported, so bootstrap's OWN warn() calls do not also land in the replay --
# they are already three lines above the closing line, and duplicating them makes
# tests/bootstrap-markers.sh's `grep -c '20-beta exited 3'` read 2.
_TALLY="${TMPDIR:-/tmp}/macboot-tally.$$"
trap 'rm -f "$_TALLY" "$_TALLY.warn"' EXIT

# Declared here, not at the module loop: finish() reads it, and finish() is also called
# from the "nothing to run" path above the loop, where `set -u` would abort on an unset
# variable.
FAILED=''

# finish <name> -- the closing screen, replacing a bare summary().
#
# Three jobs the counter line alone could not do. It TOTALS the children's counters,
# because modules are child processes and bootstrap's own MACBOOT_* only ever counted the
# state dir and the markers -- so the last thing a first run printed was "0 warnings"
# immediately after five warnings. It REPLAYS those warnings, because they are the only
# output the user has to act on and they are hundreds of lines up. And it says what to do
# NEXT, because "open a new terminal" and `chsh` are the difference between a bootstrap
# that worked and a shell that looks untouched.
finish() {
  local c s w a b d elapsed
  c=0
  s=0
  w=0
  # Printed before the counters, so the two read as one sentence: how long, then what for.
  # Minutes only above 90s -- "took 4s" is more useful than "took 0m4s".
  elapsed=$(($(date +%s) - _RUN_STARTED_AT))
  if [ "$elapsed" -ge 90 ]; then
    log "done in $((elapsed / 60))m$((elapsed % 60))s"
  else
    log "done in ${elapsed}s"
  fi
  if [ -f "$_TALLY" ]; then
    while read -r a b d; do
      c=$((c + a))
      s=$((s + b))
      w=$((w + d))
    done <"$_TALLY"
  fi
  MACBOOT_CHANGED=$((MACBOOT_CHANGED + c))
  MACBOOT_SKIPPED=$((MACBOOT_SKIPPED + s))
  MACBOOT_WARNED=$((MACBOOT_WARNED + w))
  summary "${1:-macboot}"

  if [ -s "$_TALLY.warn" ]; then
    printf '\n%sNeeds you -- these scrolled past, so here they are again:%s\n' \
      "$_C_YELLOW" "$_C_RESET" >&2
    sed 's/^W /  ! /' "$_TALLY.warn" >&2
  fi

  # No next steps after a dry run: nothing happened. None after a failure either -- the
  # next step is the FAIL line that follows.
  [ "$DRY_RUN" = "1" ] && return 0
  [ -z "$FAILED" ] || return 0
  cat >&2 <<'EOF'

Next:
  1. open a NEW terminal            this one still has the old config loaded
  2. make apps                      paste the cask lines it prints
  3. notes/MANUAL-STEPS.md          Raycast hotkey, backup, SSH keys, screensaver
Anything under "Needs you" comes first. Re-run `make all` any time; it will
say changed=0.
EOF
}

# Glob expansion is already sorted, and that sort is exactly the run order the
# numeric prefixes encode. `ls | sort` would add nothing and break on any path
# containing a space.
ALL=''
for _f in "$MACBOOT_ROOT"/scripts/[0-9][0-9]-*.sh; do
  [ -f "$_f" ] || continue
  ALL="$ALL $(basename "$_f" .sh)"
done
[ -n "$ALL" ] ||
  die "no scripts/NN-*.sh modules under $MACBOOT_ROOT (incomplete checkout?)"

# matches <module> <patterns> -- a module answers to its full name, its numeric
# prefix and its bare name, so --skip node, --skip 40 and --skip 40-node.sh all
# mean the same thing. Matching is exact per form rather than substring: with
# substrings, --only go would also select 70-claude.sh's "go" in "mongo".
matches() {
  _name="$1"
  # `set -f` first: the word splitting below is deliberate, but PATHNAME EXPANSION on
  # the same words is not. Without it, `--skip '*'` was replaced by a listing of the
  # current directory, and run from the checkout root -- which contains directories
  # literally named shell, git and claude -- `--skip 'g*'` expanded to `git` and
  # silently skipped 50-git without the user ever naming it. Restored immediately,
  # because line 113's module glob needs expansion to work.
  set -f
  # shellcheck disable=SC2086  # deliberate word splitting; see ONLY/SKIP above
  set -- $2
  set +f
  for _pat in "$@"; do
    _pat="${_pat%.sh}"
    case "$_pat" in
      "$_name" | "${_name%%-*}" | "${_name#*-}") return 0 ;;
    esac
  done
  return 1
}

# A typo in --only or --skip must not quietly do nothing: a run that skipped
# nothing because someone wrote --skip nodejs looks exactly like a success.
set -f # as in matches(): split the words, do NOT glob them
for _pat in $ONLY $SKIP; do
  _hit=0
  for _m in $ALL; do
    if matches "$_m" "$_pat"; then _hit=1; fi
  done
  [ "$_hit" = 1 ] || die "no module matches '$_pat'; have:$ALL"
done
set +f

banner

# The plan is resolved and printed in full BEFORE anything runs. A bootstrap that
# starts installing and tells you afterwards is the thing people are afraid of,
# and the skip reasons are the part worth reading: "already done" and "--skip"
# look identical once the run is over.
log "home=$MACBOOT_HOME  optional=$MACBOOT_OPTIONAL  mytools=$MACBOOT_MYTOOLS"
RUN_LIST=''
RUN_COUNT=0
for _m in $ALL; do
  _why=''
  if [ -n "$SKIP" ] && matches "$_m" "$SKIP"; then
    _why='--skip'
  elif [ -n "$ONLY" ] && ! matches "$_m" "$ONLY"; then
    _why='not in --only'
  elif [ "$DO_RESTART" != 1 ] && [ -z "$ONLY" ] && [ -f "$STATE_DIR/$_m.done" ]; then
    # --only overrides the marker: otherwise `--only 80-mytools` after a full
    # run is a silent no-op and reads as a broken module.
    _why='done earlier (--restart to redo)'
  fi
  if [ -n "$_why" ]; then
    skip "$_m -> $_why"
    continue
  fi
  RUN_LIST="$RUN_LIST $_m"
  RUN_COUNT=$((RUN_COUNT + 1))
done

if [ "$RUN_COUNT" = 0 ]; then
  log "nothing to run"
  finish "macboot"
  exit 0
fi
log "will run ($RUN_COUNT):$RUN_LIST"

if [ "$DRY_RUN" != "1" ] && [ "$MACBOOT_YES" != "1" ]; then
  # Without the tty test this read takes EOF as "no", which makes the documented
  # `curl … | bash` one-liner impossible rather than merely unconfirmed.
  [ -t 0 ] || die "stdin is not a tty: re-run with --yes (or --dry-run first)"
  printf '\nInstall software and rewrite config under %s? [y/N] ' "$MACBOOT_HOME" >&2
  read -r _reply
  case "$_reply" in y | Y | yes | YES) ;; *) die "aborted" ;; esac
fi

# Markers are machine state, so creating and clearing them goes through run() and
# a dry run leaves none behind — which is also why a dry run always plans the
# full sequence.
#
# Explicit if/then, and a die() that explains. Written as `[ -d x ] || run mkdir -p x`
# the mutation sits after the FINAL `||`, so set -e is not suppressed and a failing
# mkdir killed the shell instantly: the transcript ended on one bare
# "mkdir: Permission denied", with no module named, no summary box and exit 1. The
# realistic cause is one `sudo ./bootstrap.sh` leaving a root-owned ~/.macboot, after
# which every later non-sudo run died after module 1 for no stated reason.
if [ ! -d "$STATE_DIR" ]; then
  if ! run_untracked mkdir -p "$STATE_DIR"; then
    die "cannot create $STATE_DIR, so no module can be marked complete.
     If an earlier run used sudo, the directory is root-owned; fix with:
         sudo chown -R $(id -un) $MACBOOT_HOME/.macboot"
  fi
fi
# Scoped to the modules this invocation is actually going to run, not to the glob.
# `--restart --only 40-node` -- both flags are documented, and reaching for the two
# together is the obvious way to redo one module -- wiped all ten markers and then wrote
# none, because mark_done returns early whenever --only is set. The next plain
# ./bootstrap.sh therefore redid Homebrew, uv, nvm and the rest from the top: the hour of
# downloads the marker system exists to avoid. RUN_LIST is already ALL minus --skip/--only
# and, under --restart, is not filtered by the markers themselves, so with neither flag
# present this is identical to wiping the glob. It also stops --restart --skip from
# clearing the state of a module the user just asked to leave alone.
if [ "$DO_RESTART" = 1 ]; then
  for _m in $RUN_LIST; do
    [ -f "$STATE_DIR/$_m.done" ] || continue
    run_untracked rm -f "$STATE_DIR/$_m.done"
  done
fi

# `step` renders "[8/10]" from these two; MACBOOT_STEP_N is exported per module below.
export MACBOOT_STEP_TOTAL="$RUN_COUNT"

# mark_done <module> -- record that a module finished, when that means anything.
#
# A TARGETED run does not complete a step of the full bootstrap, so it writes no
# marker. Doing so was a quiet trap: `make apps` (--only 99) marked 99 done, so the real
# bootstrap never printed the GUI-app list; `make mytools` (--only 80) marked 80 done;
# `make module M=40-node` marked node done. Recovery needed --restart, which is
# documented for the resume case and nowhere near those targets.
mark_done() {
  if [ -n "$ONLY" ]; then
    return 0
  fi
  if [ -f "$STATE_DIR/$1.done" ]; then
    return 0
  fi
  # A marker that cannot be written is not fatal: the module DID succeed, and the only
  # consequence is that it runs again next time. Warn rather than abort, because
  # aborting here throws away a run that actually worked.
  if ! run_untracked touch "$STATE_DIR/$1.done"; then
    warn "could not write $STATE_DIR/$1.done, so $1 will run again on the next
     invocation even though it just succeeded"
  fi
  return 0
}

trap 'printf "\ninterrupted — finished modules are marked, re-run to resume\n" >&2; exit 130' INT

# Where the tools macboot installs will be, resolved once. brew_prefix() shells out to
# `brew --prefix` when brew already exists and otherwise answers from the arch, which is
# the right answer for a fresh Mac that is about to get one.
_MACBOOT_PREFIX="$(brew_prefix)"

_i=0
for _m in $RUN_LIST; do
  _i=$((_i + 1))
  export MACBOOT_STEP_N="$_i"
  log "$_i/$RUN_COUNT $_m"

  # Modules are separate child processes, so a PATH fix a module makes inside its OWN
  # process dies with it. 10-brew evals `brew shellenv`, which is why it can use brew
  # itself -- but on a fresh Mac /opt/homebrew/bin is on no inherited PATH, so the next
  # module could not. Measured in one `bootstrap.sh --dry-run --mytools` run:
  # 80-mytools reported "witness -> needs go, which comes from 10-brew.sh" about the
  # module that had just installed go, and 99-apps warned that its cask commands "cannot
  # run until 10-brew.sh has finished". 30-python installs uv into ~/.local/bin with the
  # same result for daylogs and trading-desk. Re-tested per iteration rather than once, so
  # a directory that module N creates is on PATH for module N+1.
  for _d in "$_MACBOOT_PREFIX/bin" "$_MACBOOT_PREFIX/sbin" "$MACBOOT_HOME/.local/bin"; do
    [ -d "$_d" ] || continue
    case ":$PATH:" in
      *":$_d:"*) ;;
      *) PATH="$_d:$PATH" ;;
    esac
  done
  export PATH

  # `bash "$file"`, not `"$file"`: a checkout unzipped or copied off a FAT volume
  # loses the +x bit, and "permission denied" is a poor way to learn that.
  _rc=0
  MACBOOT_TALLY="$_TALLY" bash "$MACBOOT_ROOT/scripts/$_m.sh" || _rc=$?
  if [ "$_rc" = 0 ]; then
    mark_done "$_m"
    continue
  fi

  # A failure names the module, because "exit 1" 400 lines into a transcript with
  # nine modules in it is not actionable.
  warn "$_m exited $_rc"
  FAILED="$FAILED $_m"
  if [ "$KEEP_GOING" != 1 ]; then
    finish "macboot - stopped at $_m"
    die "$_m failed (exit $_rc): fix it and re-run to resume here, or --keep-going"
  fi
done

finish "macboot"
# Exiting 0 after --keep-going swallowed a failure would make CI, and the caller's
# `&&`, report a bootstrap that did not happen.
[ -z "$FAILED" ] || die "failed modules:$FAILED"
