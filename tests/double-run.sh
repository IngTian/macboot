#!/usr/bin/env bash
# tests/double-run.sh -- the only test that actually verifies idempotency.
#
# Run the safe subset of modules FOR REAL against a scratch home, snapshot the
# tree (paths + symlink targets + sha256 of every file), run them again, then
# assert two things: the second run reported `changed=0`, and the snapshot is
# byte-identical. Either alone is insufficient -- a module can report changed=0
# while rewriting a file, and it can leave the tree identical while re-running a
# mutation that happened to be a no-op.
#
# WHAT IS EXCLUDED, AND WHY. This matters more than what is included: a test that
# quietly skips the interesting half and still prints green is worse than no test.
#
#   * 10-brew            installs Homebrew and the Brewfile into /opt/homebrew with
#                        sudo. Ignores MACBOOT_HOME entirely, needs the network, and
#                        cannot be undone by deleting a scratch directory.
#   * 30-python 40-node  pipe a vendor installer into a shell (uv, nvm) and download
#                        toolchains. Same reasons.
#   * 60-macos           writes system `defaults`. cfprefsd is a per-user daemon, so
#                        redirecting HOME does NOT contain it: the write lands in the
#                        real user's preferences. Never in an automated test.
#   * 70-claude          runs `claude plugin ...` against a live marketplace.
#   * 80-mytools         clones and builds from the network.
#   (check-unpushed.sh is not in scripts/ at all -- it is a standalone migration tool,
#    not a bootstrap step, so it is neither run nor excluded here. It has its own CI
#    job with fixture repos.)
#   * anything that changes the login shell (chsh) -- interactive password prompt.
#
# So `defaults` idempotency and Homebrew idempotency are NOT covered here, by
# anyone, ever: they stay a manual gate on a throwaway VM before a release tag.
# What IS covered is the part that has actually broken in practice -- link_once
# backing up its own symlink on every re-run, and ensure_block appending a second
# copy of its fence instead of replacing the first.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

#: Basenames eligible for a real run. An allowlist, not a denylist: an unreviewed
#: scripts/45-foo.sh must never be executed for real by a test just because nobody
#: added it to a skip list. New modules are reported as excluded until reviewed.
DOUBLE_RUN_ALLOW="${DOUBLE_RUN_ALLOW:-00-preflight.sh 20-shell.sh 50-git.sh 99-apps.sh}"

#: Where the two scratch homes live. TMPDIR by default so a run cannot dirty the
#: checkout; point it somewhere durable when you want to inspect the result.
MACBOOT_TEST_TMP="${MACBOOT_TEST_TMP:-${TMPDIR:-/tmp}}"

# Command words a module may not hand to run() if it wants a real test run. Most
# escape MACBOOT_HOME; bash/sh/zsh are here because `run bash -c '...'` hides its
# effect from --dry-run and from the scanner below alike.
FORBIDDEN='sudo|brew|chsh|defaults|defaults_set|plutil|killall|launchctl|scutil'
FORBIDDEN="$FORBIDDEN|softwareupdate|xcode-select|installer|pkgutil|dscl|systemsetup"
FORBIDDEN="$FORBIDDEN|curl|wget|npm|nvm|node|rustup|cargo|uv|pip|pip3|gem|gh|claude"
FORBIDDEN="$FORBIDDEN|ollama|mas|open|osascript|bash|sh|zsh|xargs|eval"

FAIL_N=0
_fail() {
  FAIL_N=$((FAIL_N + 1))
  warn "$*"
}

SCRATCH="$(mktemp -d "$MACBOOT_TEST_TMP/macboot-double.XXXXXX")"
PROBE_HOME="$SCRATCH/probe"
REAL_HOME="$SCRATCH/home"
mkdir -p "$PROBE_HOME" "$REAL_HOME"
# Chained: common.sh installs `trap spin_stop EXIT`, and replacing it strands a
# spinner. The tree is kept on failure -- the snapshot diff is the evidence.
_cleanup() {
  spin_stop
  [ "$FAIL_N" -gt 0 ] || rm -rf "$SCRATCH"
}
trap _cleanup EXIT

# code_lines <file> -- the file minus comments. Scanning raw text excludes
# 20-shell.sh for "chsh", which it only ever prints as advice; a scanner that
# cannot tell prose from execution excludes everything and proves nothing.
code_lines() { grep -vE '^[[:space:]]*#' "$1"; }

# strip_cmd -- drop `would `, any `env VAR=val` prefix and the command word from a
# planned-mutation line, leaving the arguments. The command word is frequently an
# absolute path outside the scratch home (that is the tool, not the target).
strip_cmd() {
  sed -E 's/^[[:space:]]*would +//; s/^(env +([A-Za-z_][A-Za-z0-9_]*=[^ ]+ +)*)?[^ ]+ *//'
}

# eligible <module-path> -- may we execute this module for real? Prints the reason
# it is refused, or nothing.
#
# Three gates, and the dynamic ones are the load-bearing pair. A source grep cannot
# tell execution from prose: 20-shell.sh contains the word `chsh` five times, all of
# them in a message explaining why it will NOT run chsh, and a scanner that excludes
# it over that excludes the one module whose link_once/ensure_block behaviour this
# test exists to check. So instead of guessing from text:
#
#   1. the allowlist -- a human decided this module is home-scoped;
#   2. run() targets that are forbidden, or are a variable the scanner cannot
#      resolve (`run "$uv" ...` could be anything);
#   3. the module's own --dry-run, into a probe home used by nothing else. Its plan
#      must name no path outside that home or the checkout, AND it must leave the
#      probe home empty. That second half is what catches a mutation smuggled past
#      run() -- measured: 30-python.sh creates ~/.cache/uv during a dry run, from a
#      read (`uv python list`) that has a side effect. A grep never sees that.
eligible() {
  _mod="$1"
  _base="$(basename "$_mod")"

  case " $DOUBLE_RUN_ALLOW " in
    *" $_base "*) ;;
    *)
      printf 'not on the reviewed allowlist\n'
      return 0
      ;;
  esac

  if code_lines "$_mod" |
    grep -qE "(^|[[:space:]]|[;&|(])run[[:space:]]+(env[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)+)?\"?(\\\$|([A-Za-z0-9_./-]*/)?($FORBIDDEN))([[:space:]\"]|$)"; then
    printf 'run() target is forbidden or is a variable the scanner cannot resolve\n'
    return 0
  fi
  # defaults_set routes through run(), so the pattern above cannot see it, and
  # cfprefsd writes to the real user's preferences whatever HOME says.
  if code_lines "$_mod" | grep -q 'defaults_set'; then
    printf 'writes system defaults, which redirecting HOME does not contain\n'
    return 0
  fi

  _probe="$PROBE_HOME/$_base"
  _plan="$SCRATCH/plan.$_base.txt"
  mkdir -p "$_probe"
  if ! MACBOOT_HOME="$_probe" HOME="$_probe" DRY_RUN=1 NO_COLOR=1 MACBOOT_YES=1 \
    bash "$_mod" >"$_plan" 2>&1; then
    printf 'its own --dry-run exited non-zero (see %s)\n' "$_plan"
    return 0
  fi
  _outside="$(grep '^[[:space:]]*would ' "$_plan" | strip_cmd | tr ' ' '\n' |
    grep '^/' | grep -vE "^($_probe|$MACBOOT_ROOT)/|^/dev/null$|^(/private)?/tmp/|^/var/folders/" |
    head -1 || true)"
  if [ -n "$_outside" ]; then
    printf 'plans a write outside the scratch home: %s\n' "$_outside"
    return 0
  fi
  if [ -n "$(find "$_probe" -mindepth 1 2>/dev/null | head -1)" ]; then
    printf 'wrote into the scratch home during its own dry run\n'
    return 0
  fi
}

# snapshot <dir> <out> -- paths, symlink TARGETS and content hashes.
#
# -L before -f, because -f follows a symlink: without that ordering a link and a
# copy of the same bytes are indistinguishable, and link_once's whole contract is
# about which of the two you got. Directories are listed too, so a re-run that
# creates <file>.bak.<stamp> shows up as an added path even though nothing changed.
snapshot() {
  find "$1" -mindepth 1 | LC_ALL=C sort | while IFS= read -r _p; do
    _rel="${_p#"$1"/}"
    if [ -L "$_p" ]; then
      printf 'link %s -> %s\n' "$_rel" "$(readlink "$_p")"
    elif [ -d "$_p" ]; then
      printf 'dir  %s\n' "$_rel"
    elif [ -f "$_p" ]; then
      printf 'file %s %s\n' "$_rel" "$(shasum -a 256 <"$_p" | awk '{print $1}')"
    else
      printf 'other %s\n' "$_rel"
    fi
  done >"$2"
}

# do_pass <n> -- run every eligible module for real, return the total `changed`.
#
# Modules are invoked directly rather than through bootstrap.sh because bootstrap's
# state markers make the second run a no-op for the wrong reason (`done earlier`),
# which would make this test pass without comparing anything. Each module's own
# summary line is the counter this test reads.
#
# (An earlier version of this comment also blamed a bootstrap function called
# absorb_counts() for mangling the aggregate. No such function exists -- `grep -c
# absorb bootstrap.sh` is 0 -- so half the justification for the design was invented.
# The marker reason is the real one. bootstrap.sh's own marker semantics are covered
# separately by tests/bootstrap-markers.sh, because nothing here executes it.)
#
# MACBOOT_STAMP is deliberately NOT pinned across the two passes: link_once names
# backups <file>.bak.<stamp>, so a module that re-backs-up an existing symlink
# leaves a second, differently-named file -- which the snapshot diff then shows.
# Pinning the stamp would let that bug overwrite its own evidence.
do_pass() {
  _pass="$1"
  _total=0
  _n=0
  for _mod in $MODULES; do
    _n=$((_n + 1))
    _base="$(basename "$_mod")"
    _out="$SCRATCH/run$_pass.$_base.txt"
    _rc=0
    # HOME is redirected as well as MACBOOT_HOME: `git config --global` and every
    # ~/-relative tool honour HOME, not our variable, so without this a "scratch"
    # run edits the owner's real dotfiles.
    MACBOOT_HOME="$REAL_HOME" HOME="$REAL_HOME" DRY_RUN=0 NO_COLOR=1 MACBOOT_YES=1 \
      bash "$_mod" >"$_out" 2>&1 || _rc=$?
    [ "$_rc" = 0 ] || _fail "pass $_pass: $_base exited $_rc (see $_out)"

    # summary() prints "  <changed> changed   <skipped> skipped ...".
    #
    # `|| true` is load-bearing, not defensive noise. Under `set -euo pipefail` a grep
    # that matches nothing exits 1, pipefail propagates it, the assignment inherits it
    # and set -e then killed this function INSIDE the loop: no snapshot was taken, no
    # assertion ran, the _fail below never executed, and because FAIL_N was still 0
    # the EXIT trap deleted the entire scratch tree -- including both run logs. The
    # test destroyed its own evidence in exactly the case worth investigating, and the
    # diagnostic written for that case was unreachable. 00-preflight.sh is on the
    # allowlist and dies on three fresh-machine conditions (Rosetta, missing Xcode
    # CLT, missing /bin/bash), so this was reachable, not theoretical.
    #
    # Every box is SUMMED rather than `tail -1`: a module that delegates work to a
    # child which prints its own box would otherwise have the earlier counts silently
    # dropped, reading as changed=0. 10-brew.sh and 80-mytools.sh each contain two
    # summary calls today.
    _c="$(awk '{ for (i = 1; i < NF; i++) if ($(i+1) == "changed") s += $i } \
                END { print s + 0 }' "$_out" 2>/dev/null || true)"
    if [ -z "$_c" ] || ! grep -q 'changed' "$_out"; then
      _fail "pass $_pass: $_base printed no summary line; its counters are unreadable
     (log kept at $_out)"
      _c=0
    fi
    _total=$((_total + _c))
    MODULE_CHANGED="$MODULE_CHANGED $_base=$_c"
    progress "$_n" "$MODULE_N" "pass $_pass: $_base"
  done
  PASS_CHANGED="$_total"
}

# ---------------------------------------------------------------------------

step "select the modules that may run for real"

MODULES=''
MODULE_N=0
for _m in "$MACBOOT_ROOT"/scripts/[0-9][0-9]-*.sh; do
  [ -f "$_m" ] || continue
  # `|| true`: head closing the pipe early is a SIGPIPE that pipefail would
  # otherwise turn into an aborted test run.
  _why="$(eligible "$_m" | head -1 || true)"
  if [ -n "$_why" ]; then
    skip "$(basename "$_m") -> $_why"
    continue
  fi
  MODULES="$MODULES $_m"
  MODULE_N=$((MODULE_N + 1))
  ok "$(basename "$_m") -> eligible"
done

[ "$MODULE_N" -gt 0 ] || die "no module is eligible for a real run, so this test
     would prove nothing. Fix the exclusion reasons above rather than trusting the
     idempotency claim in the README."

if [ "$DRY_RUN" = "1" ]; then
  # Not a hedge: this test's whole method is executing modules for real, so under
  # DRY_RUN=1 the honest thing is to print the plan and stop, rather than run
  # nothing and report success.
  log "DRY_RUN=1: selection only, no module was executed"
  summary "double-run (plan)"
  exit 0
fi

MODULE_CHANGED=''
PASS_CHANGED=0

step "pass 1 of $MODULE_N module(s) into $REAL_HOME"
do_pass 1
FIRST_CHANGED="$PASS_CHANGED"
snapshot "$REAL_HOME" "$SCRATCH/snap1.txt"
ok "pass 1: changed=$FIRST_CHANGED, $(wc -l <"$SCRATCH/snap1.txt" | tr -d ' ') paths"

step "pass 2 (identical invocation)"
MODULE_CHANGED=''
do_pass 2
SECOND_CHANGED="$PASS_CHANGED"
snapshot "$REAL_HOME" "$SCRATCH/snap2.txt"

step "assert"

# A first pass that changed nothing means the modules did not reach their writes
# (missing brew, a skipped branch), and then changed=0 on pass 2 is vacuous.
if [ "$FIRST_CHANGED" -gt 0 ]; then
  ok "pass 1 made $FIRST_CHANGED change(s), so pass 2 has something to be idempotent about"
else
  _fail "pass 1 made no change at all: this run proves nothing about idempotency"
fi

if [ "$SECOND_CHANGED" -eq 0 ]; then
  ok "pass 2 reported changed=0"
else
  _fail "pass 2 reported changed=$SECOND_CHANGED (per module:$MODULE_CHANGED)"
fi

if diff -u "$SCRATCH/snap1.txt" "$SCRATCH/snap2.txt" >"$SCRATCH/snap.diff"; then
  ok "filesystem snapshot byte-identical across both passes"
else
  _fail "the scratch home changed between passes:"
  sed 's/^/      /' "$SCRATCH/snap.diff" >&2
fi

[ "$FAIL_N" -gt 0 ] && log "evidence kept in $SCRATCH"
summary "double-run"
[ "$FAIL_N" -eq 0 ] || die "$FAIL_N idempotency assertion(s) failed"
