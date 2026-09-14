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

step "FAIL-OPEN 5: a PARTIAL scan (an unreadable directory) is not a pass"
# SCAN_ERRORS was incremented inside a command substitution, so the "a partial scan
# cannot produce a clean verdict" gate could never fire for a find-level failure: only a
# root that did not EXIST was counted. One chmod-000 directory beside a readable repo gave
# a warning on screen, "0 warnings" in the summary box, and exit 0 -- while the repo
# behind it held a commit that existed nowhere else. --bundle had no such gate at all.
PART="$SCRATCH/partial"
mkdir -p "$PART/visible" "$PART/locked"
mkrepo "$PART/visible" partvis >/dev/null
git init -q "$PART/locked/secret"
git -C "$PART/locked/secret" commit -q --allow-empty -m 'exists in one place only'
chmod 000 "$PART/locked"
want "--verify refuses a partial scan" "yes" "$(nonzero "$(verify_rc "$PART")")"
want "the summary counted the warning" "0" \
  "$(grep -c '0 warnings' "$SCRATCH/out.txt" || true)"
_rc=0
env MACBOOT_REPO_ROOTS="$PART" NO_COLOR=1 bash "$TOOL" --bundle "$SCRATCH/pb" \
  >/dev/null 2>&1 || _rc=$?
want "--bundle refuses a partial scan too" "yes" "$(nonzero "$_rc")"
chmod 755 "$PART/locked"

step "FAIL-OPEN 6: a SUBMODULE's unpushed work is not the parent's to vouch for"
# Every nested .git was pruned as "nested, so its refs live in the parent's object store".
# True of a linked worktree, false of a submodule: its objects live in
# <super>/.git/modules/<name>, so the commit is in no store but its own.
SUB="$SCRATCH/sub"
mkdir -p "$SUB/area"
git init -q --bare "$SCRATCH/subsuper.git"
git init -q --bare "$SCRATCH/subchild.git"
git init -q "$SCRATCH/subsrc"
git -C "$SCRATCH/subsrc" commit -q --allow-empty -m subfirst
git -C "$SCRATCH/subsrc" remote add origin "$SCRATCH/subchild.git"
git -C "$SCRATCH/subsrc" push -q -u origin HEAD:refs/heads/main
git init -q "$SUB/area/super"
git -C "$SUB/area/super" commit -q --allow-empty -m supfirst
git -C "$SUB/area/super" remote add origin "$SCRATCH/subsuper.git"
git -C "$SUB/area/super" -c protocol.file.allow=always \
  submodule add -q "$SCRATCH/subchild.git" sub 2>/dev/null
git -C "$SUB/area/super" commit -q -m 'add sub'
git -C "$SUB/area/super" push -q -u origin HEAD:refs/heads/main
git -C "$SUB/area/super/sub" checkout -q -B main
git -C "$SUB/area/super/sub" commit -q --allow-empty -m 'SUBMODULE ONLY COPY'
want "--verify refuses" "yes" "$(nonzero "$(verify_rc "$SUB")")"

step "a linked worktree still FOLDS, including under a symlinked root"
# The fold key is `git rev-parse --git-common-dir`, which the MAIN checkout answers with a
# relative `.git` (inheriting the caller's spelling of the path) while a LINKED worktree
# answers with an absolute realpath. Any symlink component -- macOS's /tmp and /var are
# both symlinks -- made the two differ, so the same repository was scanned twice.
FOLD="$SCRATCH/fold"
mkdir -p "$FOLD/area"
FW="$(mkrepo "$FOLD" folded)"
git -C "$FW" worktree add -q --detach "$FW/../folded-side" HEAD
verify_rc "$FOLD" >/dev/null
want "the two checkouts folded into one repo" "1" \
  "$(grep -c '1 repos (1 extra' "$SCRATCH/out.txt" || true)"

step "MODE COLLAPSE: two mode flags must be refused, not silently reduced to one"
# Each arm assigned MODE unconditionally, so `--verify --bundle DIR` -- the obvious
# "check and rescue in one pass" -- ran only the bundle arm and exited 0 with findings on
# screen, and `--bundle DIR --verify` silently created no bundle and no destination.
want "--verify --bundle is refused" "yes" \
  "$(nonzero "$(
    rc=0
    env MACBOOT_REPO_ROOTS="$REAL" NO_COLOR=1 bash "$TOOL" --verify \
      --bundle "$SCRATCH/mb1" >"$SCRATCH/out.txt" 2>&1 || rc=$?
    printf '%s' "$rc"
  )")"
want "the refusal explains itself" "yes" "$(says 'mutually exclusive')"
want "--bundle --verify is refused" "yes" \
  "$(nonzero "$(
    rc=0
    env MACBOOT_REPO_ROOTS="$REAL" NO_COLOR=1 bash "$TOOL" --bundle "$SCRATCH/mb2" \
      --verify >/dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
  )")"

step "DATA LOSS: names differing only in CASE must not share one bundle"
# APFS is case-insensitive by default, so `Wiki` and `wiki` are one path. The taken-name
# test was case-SENSITIVE, so it matched neither, both resolved to the same target, and
# the second `bundle create` overwrote the first repo's only backup -- while the tool
# printed "written and verified" twice and exited 0.
CASE="$SCRATCH/case"
mkdir -p "$CASE/a/area/Wiki" "$CASE/b/area/wiki"
for d in "$CASE/a/area/Wiki" "$CASE/b/area/wiki"; do
  git init -q "$d"
  git -C "$d" commit -q --allow-empty -m "only-copy-$(basename "$(dirname "$(dirname "$d")")")"
done
CBDIR="$SCRATCH/case-bundles"
env MACBOOT_REPO_ROOTS="$CASE/a:$CASE/b" NO_COLOR=1 \
  bash "$TOOL" --bundle "$CBDIR" >"$SCRATCH/out.txt" 2>&1 || true
want "two distinct bundle files exist" "2" \
  "$(find "$CBDIR" -name '*.bundle' | wc -l | tr -d ' ')"
missing=0
for d in "$CASE/a/area/Wiki" "$CASE/b/area/wiki"; do
  sha="$(git -C "$d" rev-parse HEAD)"
  found=0
  for b in "$CBDIR"/*.bundle; do
    if git bundle list-heads "$b" 2>/dev/null | grep -q "$sha"; then found=1; fi
  done
  [ "$found" = 1 ] || missing=$((missing + 1))
done
want "neither repo's only copy is missing from every bundle" "0" "$missing"

step "a relative --bundle destination must land where the user named it"
# `git -C "$repo" bundle create <relative>` resolves the path inside the REPO, so
# `cd /Volumes/Backup && ... --bundle .` wrote every bundle onto the disk being erased
# and left the external drive empty, reporting "written and verified" for each.
RELR="$SCRATCH/rel"
mkdir -p "$RELR/area"
RR="$(mkrepo "$RELR" relative)"
git -C "$RR" commit -q --allow-empty -m 'exists in one place only'
mkdir -p "$RELR/dest"
(
  cd "$RELR/dest" || exit 1
  env MACBOOT_REPO_ROOTS="$RELR" NO_COLOR=1 bash "$TOOL" --bundle . >/dev/null 2>&1
) || true
want "the bundle is in the named destination" "1" \
  "$(find "$RELR/dest" -name '*.bundle' | wc -l | tr -d ' ')"
want "no bundle leaked into the repo being wiped" "0" \
  "$(find "$RR" -name '*.bundle' | wc -l | tr -d ' ')"

step "a bundle that lists every ref but cannot be unbundled is not a backup"
# `git bundle verify` reads only the HEADER: it exits 0 on a bundle truncated to 60% and
# on one with a flipped byte, while `git clone` of the same file dies with "early EOF".
# The re-run fast path trusted the ref list alone and answered "already holds every
# current ref" -- certifying an unrestorable file.
TR="$SCRATCH/trunc"
mkdir -p "$TR/area/proj"
git init -q "$TR/area/proj"
for i in 1 2 3 4 5; do
  printf 'line %s\n' "$i" >>"$TR/area/proj/f"
  git -C "$TR/area/proj" add f
  git -C "$TR/area/proj" commit -q -m "c$i"
done
TBD="$SCRATCH/trunc-bundles"
env MACBOOT_REPO_ROOTS="$TR" NO_COLOR=1 bash "$TOOL" --bundle "$TBD" >/dev/null 2>&1 || true
TB="$(find "$TBD" -name '*.bundle' | head -1)"
GOODSZ="$(wc -c <"$TB" | tr -d ' ')"
dd if="$TB" of="$TB.cut" bs=1 count=$((GOODSZ * 60 / 100)) 2>/dev/null
mv "$TB.cut" "$TB"
want "git's own 'bundle verify' is fooled by the truncation" "0" \
  "$(
    rc=0
    git -C "$TR/area/proj" bundle verify "$TB" >/dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
  )"
env MACBOOT_REPO_ROOTS="$TR" NO_COLOR=1 bash "$TOOL" --bundle "$TBD" \
  >"$SCRATCH/out.txt" 2>&1 || true
want "macboot noticed and said so" "yes" "$(says 'does NOT unbundle')"
want "the bundle was rewritten to its full size" "$GOODSZ" "$(wc -c <"$TB" | tr -d ' ')"

step "a stash behind a LIVE origin must still be bundled"
# BUNDLE_ME was set only by check_origin, so a repo with a working origin plus a
# local-only stash got "no repo needs a bundle", exit 0, and no destination directory --
# while check_stash's own message tells the user "--bundle does" carry stashes.
STR="$SCRATCH/stash"
mkdir -p "$STR/area"
SR="$(mkrepo "$STR" stashed)"
printf 'x\n' >"$SR/tracked"
git -C "$SR" add tracked
git -C "$SR" commit -q -m 'add tracked'
git -C "$SR" push -q origin HEAD:refs/heads/main
printf 'secret work\n' >"$SR/tracked"
git -C "$SR" stash -q
SBD="$SCRATCH/stash-bundles"
env MACBOOT_REPO_ROOTS="$STR" NO_COLOR=1 bash "$TOOL" --bundle "$SBD" >/dev/null 2>&1 || true
want "a bundle was written for it" "1" \
  "$(find "$SBD" -name '*.bundle' 2>/dev/null | wc -l | tr -d ' ')"
want "and it carries refs/stash" "yes" \
  "$(git bundle list-heads "$(find "$SBD" -name '*.bundle' | head -1)" 2>/dev/null |
    grep -q 'refs/stash' && echo yes || echo no)"

step "an origin that answers with ZERO refs is a finding, not a note"
# refs/remotes/origin/* is a LOCAL cache that survives the server being emptied, so every
# later check cleared the repo: `branch -vv` still showed an upstream it was not ahead of.
EMR="$SCRATCH/empty-origin"
mkdir -p "$EMR/area"
ER="$(mkrepo "$EMR" emptied)"
git -C "$SCRATCH/emptied.git" update-ref -d refs/heads/main
want "the server really advertises no refs" "0" \
  "$(git -C "$ER" ls-remote origin 2>/dev/null | wc -l | tr -d ' ')"
want "--verify refuses" "yes" "$(nonzero "$(verify_rc "$EMR")")"

step "a detached HEAD inside a LINKED worktree is examined too"
# check_detached_and_tags ran once per repo, on the folded main checkout, so a worktree's
# detached HEAD was never asked about -- and a lost worktree is this file's own
# motivating incident.
DWT="$SCRATCH/detwt"
mkdir -p "$DWT/area"
DW="$(mkrepo "$DWT" detwt)"
git -C "$DW" worktree add -q --detach "$DW/../detwt-side" HEAD
git -C "$DW/../detwt-side" commit -q --allow-empty -m 'DETACHED WORKTREE ONLY COPY'
want "--verify refuses" "yes" "$(nonzero "$(verify_rc "$DWT")")"
want "the finding names the worktree it is in" "yes" "$(says 'HEAD is detached at .* in ')"

step "tag noise is suppressed only when there is no origin at all"
# `--not --remotes` subtracts nothing with no remote-tracking refs, so with no origin
# EVERY tag reads as unpushed -- a third finding on a repo already condemned twice.
# Suppression is keyed on the origin URL, which is exactly the condition under which
# check_origin has already produced a finding, so it can never turn a red green.
NOR="$SCRATCH/noremote"
mkdir -p "$NOR/area/tagged"
git init -q "$NOR/area/tagged"
git -C "$NOR/area/tagged" commit -q --allow-empty -m first
git -C "$NOR/area/tagged" tag -a v1 -m v1
want "--verify still refuses (the no-origin finding stands)" "yes" "$(nonzero "$(verify_rc "$NOR")")"
want "but the redundant tag line is gone" "0" \
  "$(grep -c 'tag(s) point at' "$SCRATCH/out.txt" || true)"

# ---------------------------------------------------------------------------

summary "check-unpushed fixtures"
if [ "$FAIL_N" -gt 0 ]; then
  die "$FAIL_N assertion(s) failed; evidence kept in $SCRATCH"
fi
