#!/usr/bin/env bash
# tests/check-unpushed.sh -- fixture tests for the migration gate.
#
# Every case here is a way the gate said "nothing to lose" about work it had not
# examined, or destroyed a backup while reporting success. A tool whose only job is to
# be believed when it says a disk is safe to wipe needs its FAIL-OPEN paths tested, not
# just its happy path -- a false green here costs commits that exist nowhere else.
#
# All fixtures are local: `origin` is a bare repo on disk, so nothing depends on GitHub
# being up to prove a local-only check.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

MACBOOT_TEST_TMP="${MACBOOT_TEST_TMP:-${TMPDIR:-/tmp}}"
DRY_RUN=0
TOOL="$MACBOOT_ROOT/check-unpushed.sh"

FAIL_N=0
_fail() {
  FAIL_N=$((FAIL_N + 1))
  warn "$*"
}
want() {
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    _fail "$1: expected [$2], got [$3]"
  fi
}

SCRATCH="$(mktemp -d "$MACBOOT_TEST_TMP/macboot-gate.XXXXXX")"
_cleanup() {
  spin_stop
  [ "$FAIL_N" -gt 0 ] || rm -rf "$SCRATCH"
}
trap _cleanup EXIT

# Isolated git identity: the tool is run against fixtures, and inheriting the caller's
# global config would make these results depend on the machine.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# mkrepo <root> <name> -- a repo at <root>/area/<name> pushed to a local bare origin.
mkrepo() {
  local r="$1/area/$2"
  mkdir -p "$r"
  git init -q --bare "$SCRATCH/$2.git"
  git init -q "$r"
  git -C "$r" commit -q --allow-empty -m first
  git -C "$r" remote add origin "$SCRATCH/$2.git"
  git -C "$r" push -q -u origin HEAD:refs/heads/main
  git -C "$r" branch -q -M main 2>/dev/null || true
  git -C "$r" branch -q --set-upstream-to=origin/main main 2>/dev/null || true
  printf '%s\n' "$r"
}

# verify_rc <roots> [env...] -- exit code of --verify over those roots
verify_rc() {
  local roots="$1"
  shift
  local rc=0
  env MACBOOT_REPO_ROOTS="$roots" NO_COLOR=1 "$@" \
    bash "$TOOL" --verify >"$SCRATCH/out.txt" 2>&1 || rc=$?
  printf '%s' "$rc"
}
nonzero() { [ "$1" != 0 ] && echo yes || echo no; }
# Findings appear in both the per-repo report and the remediation block, so assert
# presence rather than an exact count -- the count is a fact about the output layout,
# not about the behaviour under test.
says() { [ "$(grep -c "$1" "$SCRATCH/out.txt" || true)" -gt 0 ] && echo yes || echo no; }

# ---------------------------------------------------------------------------

step "a clean, fully pushed repo passes"
CLEAN="$SCRATCH/clean"
mkdir -p "$CLEAN"
mkrepo "$CLEAN" pushed >/dev/null
want "--verify exits 0" "0" "$(verify_rc "$CLEAN")"

step "FAIL-OPEN 1: a SYMLINKED root must still be scanned"
# find without -H does not follow a symlinked root, while the tool's own
# `[ ! -d "$root" ]` guard does -- so the scan returned nothing and --verify exited 0
# over a tree full of unpushed work. `ln -s /Volumes/Data/devpro ~/devpro` is an
# ordinary arrangement, and macOS's /tmp is itself a symlink.
REAL="$SCRATCH/real"
mkdir -p "$REAL"
AHEAD="$(mkrepo "$REAL" ahead)"
git -C "$AHEAD" commit -q --allow-empty -m 'exists in one place only'
ln -s "$REAL" "$SCRATCH/linked"
want "unpushed work is found through the symlink" "yes" "$(nonzero "$(verify_rc "$SCRATCH/linked")")"
want "the scan reported repos, not 'nothing was checked'" "0" \
  "$(grep -c 'no git repos found' "$SCRATCH/out.txt" || true)"

step "FAIL-OPEN 2: a bad MACBOOT_REPO_DEPTH must not read as 'all clear'"
want "a non-numeric depth is refused" "yes" \
  "$(nonzero "$(verify_rc "$REAL" MACBOOT_REPO_DEPTH=four)")"
want "the refusal explains itself" "1" \
  "$(grep -c 'must be a whole number' "$SCRATCH/out.txt" || true)"

step "FAIL-OPEN 3: scanning zero repos is not a pass"
mkdir -p "$SCRATCH/empty"
want "--verify refuses an empty root" "yes" "$(nonzero "$(verify_rc "$SCRATCH/empty")")"
want "--report still exits 0 (reporting is not gating)" "0" \
  "$(
    rc=0
    env MACBOOT_REPO_ROOTS="$SCRATCH/empty" NO_COLOR=1 bash "$TOOL" --report \
      >/dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
  )"

step "FAIL-OPEN 4: a mistyped root is not a pass"
want "--verify refuses a root that does not exist" "yes" \
  "$(nonzero "$(verify_rc "$SCRATCH/does-not-exist")")"

step "CRASH: a non-numeric timeout must not abort mid-scan"
want "a non-numeric timeout is refused up front" "yes" \
  "$(nonzero "$(verify_rc "$REAL" MACBOOT_REMOTE_TIMEOUT=8s)")"
want "no arithmetic error leaked" "0" \
  "$(grep -c 'value too great for base' "$SCRATCH/out.txt" || true)"

step "BLIND SPOT: a detached-HEAD commit is work that exists in one place"
DET="$SCRATCH/det"
mkdir -p "$DET"
D="$(mkrepo "$DET" detached)"
git -C "$D" checkout -q --detach
git -C "$D" commit -q --allow-empty -m 'detached work'
want "--verify refuses" "yes" "$(nonzero "$(verify_rc "$DET")")"
want "the finding names the detached HEAD" "yes" "$(says 'HEAD is detached')"

step "BLIND SPOT: a local tag on unpushed work"
TAG="$SCRATCH/tag"
mkdir -p "$TAG"
G="$(mkrepo "$TAG" tagged)"
git -C "$G" commit -q --allow-empty -m 'to be tagged'
git -C "$G" tag -a v9 -m v9
want "--verify refuses" "yes" "$(nonzero "$(verify_rc "$TAG")")"
want "the finding mentions tags" "yes" "$(says 'tag(s) point at')"

step "BLIND SPOT: an uncommitted edit in a LINKED worktree"
WT="$SCRATCH/wt"
mkdir -p "$WT"
W="$(mkrepo "$WT" withworktree)"
echo hello >"$W/tracked"
git -C "$W" add tracked
git -C "$W" commit -q -m 'add tracked'
git -C "$W" push -q origin main 2>/dev/null || git -C "$W" push -q origin HEAD:main
git -C "$W" worktree add -q --detach "$W/../side" HEAD 2>/dev/null
echo edited >"$W/../side/tracked"
want "--verify refuses" "yes" "$(nonzero "$(verify_rc "$WT")")"
want "the finding names the worktree" "yes" "$(says 'linked worktree')"

step "DATA LOSS: three same-named repos must produce three distinct bundles"
# The de-collision renamed only the SECOND repo and never re-checked the new name, and
# the fallback used the *area* directory, which repeats across roots -- so repo 2's
# bundle was silently overwritten by repo 3 while the tool printed
# "area-wiki.bundle written and verified" for both.
COL="$SCRATCH/col"
for n in 1 2 3; do
  mkdir -p "$COL/r$n/area/wiki"
  git init -q "$COL/r$n/area/wiki"
  git -C "$COL/r$n/area/wiki" commit -q --allow-empty -m "only-copy-$n"
done
BDIR="$SCRATCH/bundles"
env MACBOOT_REPO_ROOTS="$COL/r1:$COL/r2:$COL/r3" NO_COLOR=1 \
  bash "$TOOL" --bundle "$BDIR" >"$SCRATCH/out.txt" 2>&1 || true
want "three bundle files exist" "3" "$(find "$BDIR" -name '*.bundle' | wc -l | tr -d ' ')"
# Every repo's unique commit must appear in some bundle.
missing=0
for n in 1 2 3; do
  sha="$(git -C "$COL/r$n/area/wiki" rev-parse HEAD)"
  found=0
  for b in "$BDIR"/*.bundle; do
    if git bundle list-heads "$b" 2>/dev/null | grep -q "$sha"; then found=1; fi
  done
  [ "$found" = 1 ] || missing=$((missing + 1))
done
want "no repo's only copy is missing from every bundle" "0" "$missing"

# ---------------------------------------------------------------------------

summary "check-unpushed fixtures"
if [ "$FAIL_N" -gt 0 ]; then
  die "$FAIL_N assertion(s) failed; evidence kept in $SCRATCH"
fi
