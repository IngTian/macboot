#!/usr/bin/env bash
# check-unpushed.sh -- Phase 0: does any commit on this machine exist in one place only?
#
# Called "check" and not "rescue" because it almost never rescues: --verify and
# --report only read, and the one write it can make (--bundle) goes to a directory
# you name. It never pushes and never creates a remote.
#
# It exists because `git status` says "nothing to commit, working tree clean" in all
# four states that actually lose work, and none of them appear in `git log`:
#
#   1. origin configured but deleted -- 189 commits behind an origin that answers
#      "Repository not found", and git does not notice until you push, so the only
#      honest check is to ask the server.
#   2. a stash -- not a commit, invisible to every "am I pushed?" one-liner. Two
#      stashes here name branches that exist nowhere else.
#   3. a local branch with no upstream, or ahead of one -- one repo has 31 local
#      branches against 23 remote-tracking refs.
#   4. uncommitted changes to tracked files.
#
# A worktree under /private/tmp was already lost to tmp cleanup, so none of this is
# hypothetical.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

#: Colon-separated roots to walk. Default is the layout on the source machine.
MACBOOT_REPO_ROOTS="${MACBOOT_REPO_ROOTS:-$MACBOOT_HOME/devpro}"

#: Seconds to wait for `git ls-remote`. A host that blackholes packets leaves git
#: sitting on the TCP default (~75s), which over the 45 repos here is most of an
#: hour -- long enough that the gate gets killed and skipped instead of read.
MACBOOT_REMOTE_TIMEOUT="${MACBOOT_REMOTE_TIMEOUT:-8}"

#: find(1) depth. Repos sit at <root>/<area>/<repo>/.git, i.e. depth 3; 4 leaves a
#: level of slack without walking a node_modules tree for a minute.
MACBOOT_REPO_DEPTH="${MACBOOT_REPO_DEPTH:-4}"

#: Non-zero when any root could not be scanned. "I found nothing" and "I could not
#: look" must never share an exit code in a tool whose entire job is to be trusted
#: when it says there is nothing to lose.
SCAN_ERRORS=0

# _require_int <name> <value> <min> -- refuse to start on a knob that is not a number.
#
# Both of these were reproduced, and both turned this tool into a liar rather than an
# error:
#
#   MACBOOT_REMOTE_TIMEOUT=8s  ->  `_t_max=$((_t_secs * 5))` died with
#     "8s: value too great for base (error token is "8s")". An arithmetic expansion
#     error is FATAL in a non-interactive shell no matter what `|| rc=$?` wraps the
#     caller, so the scan stopped mid-way with no report and no way to tell which
#     repos were never looked at.
#   MACBOOT_REPO_DEPTH=four   ->  find printed nothing, its stderr went to /dev/null,
#     and --verify announced "no git repos found ... nothing was checked" and exited 0
#     over a root holding six repos with findings.
_require_int() {
  case "$2" in
    '' | *[!0-9]*)
      die "$1 must be a whole number of ${4:-units}, got '$2'.
     Refusing to scan: a bad value here makes this tool report 'nothing to lose'
     when it simply could not look."
      ;;
  esac
  [ "$2" -ge "$3" ] ||
    die "$1 must be at least $3, got '$2'"
}
_require_int MACBOOT_REMOTE_TIMEOUT "$MACBOOT_REMOTE_TIMEOUT" 1 seconds
_require_int MACBOOT_REPO_DEPTH "$MACBOOT_REPO_DEPTH" 1 "directory levels"

usage() {
  cat <<'EOF'
Usage: check-unpushed.sh [--report | --verify | --bundle <dir>] [--dry-run]

  --report          human report (default). Exits 0 whatever it finds.
  --verify          same checks, exits non-zero on ANY finding. The gate and CI
                    call this. Reads only: it makes no change of any kind.
  --bundle <dir>    for repos whose origin is missing or dead, write
                    <dir>/<repo>.bundle (--all) and `git bundle verify` it.
                    Exits non-zero if any bundle could not be verified.

Environment: MACBOOT_REPO_ROOTS (colon-separated, default $HOME/devpro),
MACBOOT_REMOTE_TIMEOUT (seconds, default 8), MACBOOT_REPO_DEPTH (default 4).

Repos with findings are printed to stdout as "<path><TAB><findings>" so a caller
can read the list; all narration goes to stderr.
EOF
}

# _timeout <seconds> <cmd...> -- a deadline for one read-only command.
# A fresh macOS has no coreutils `timeout` (this runs before Homebrew), so poll a
# background pid instead. Returns 124 on expiry, like coreutils does, because
# "offline or slow" and "the repo is gone" are different findings.
_timeout() {
  _t_secs="$1"
  shift
  "$@" >/dev/null 2>&1 &
  _t_pid=$!
  _t_ticks=0
  _t_max=$((_t_secs * 5))
  while kill -0 "$_t_pid" 2>/dev/null; do
    if [ "$_t_ticks" -ge "$_t_max" ]; then
      kill -TERM "$_t_pid" 2>/dev/null || true
      wait "$_t_pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.2
    _t_ticks=$((_t_ticks + 1))
  done
  _t_rc=0
  wait "$_t_pid" 2>/dev/null || _t_rc=$?
  return "$_t_rc"
}

# ---------------------------------------------------------------------------
# Discovery. Indexed arrays are fine in bash 3.2; "${arr[@]}" on an EMPTY one is
# not (set -u aborts the run), so every list here is indexed against a count.
# ---------------------------------------------------------------------------

REPO_N=0
REPO_PATH=()
REPO_COMMON=()
REPO_FIND=()
REPO_NOTE=()
REPO_BUNDLE=()
FOLDED=0

# _remember <repo> -- add a repo unless we already have the same repository under
# another path. `git rev-parse --git-common-dir` is the identity: on this machine
# ea-world-service-bpgeom is a SIBLING worktree of ea-world-service, so a
# path-based scan reports the same 614 commits, 3 stashes and 26 dead upstreams
# twice, and --bundle would write two identical bundles. When both the main
# checkout and a linked worktree turn up, the main checkout wins (its git dir IS
# the common dir), because its working tree is the one `git status` should judge.
_remember() {
  local repo common gitdir j
  repo="$1"
  common="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null || true)"
  case "$common" in
    # Not a readable repo at all (a dangling worktree pointer). Keep it under its
    # own path so check_repo can report it instead of silently dropping it.
    '') common="$repo" ;;
    /*) ;;
    *) common="$repo/$common" ;;
  esac
  gitdir="$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null || true)"
  j=0
  while [ "$j" -lt "$REPO_N" ]; do
    if [ "${REPO_COMMON[$j]}" = "$common" ]; then
      [ "$gitdir" = "$common" ] && REPO_PATH[j]="$repo"
      FOLDED=$((FOLDED + 1))
      return 0
    fi
    j=$((j + 1))
  done
  REPO_PATH[REPO_N]="$repo"
  REPO_COMMON[REPO_N]="$common"
  REPO_N=$((REPO_N + 1))
}

discover_repos() {
  local roots root repo gitpath accepted
  roots="$MACBOOT_REPO_ROOTS"
  while [ -n "$roots" ]; do
    case "$roots" in
      *:*)
        root="${roots%%:*}"
        roots="${roots#*:}"
        ;;
      *)
        root="$roots"
        roots=''
        ;;
    esac
    [ -n "$root" ] || continue
    if [ ! -d "$root" ]; then
      # Counted, not just warned. A mistyped root ($HOME/dev for $HOME/devpro) used to
      # warn and then let --verify exit 0, so the gate said "all clear" about a
      # directory it had never opened.
      SCAN_ERRORS=$((SCAN_ERRORS + 1))
      warn "repo root does not exist, nothing was scanned there: $root"
      continue
    fi

    # `.git` by name, not as a directory: a worktree checkout and a submodule each
    # have a .git *file*. Excluding */.git/* keeps the walk out of .git/modules/,
    # which would otherwise report every submodule a second time. A heredoc rather
    # than a pipe, because a `while read` right of a pipe runs in a subshell and
    # every repo it appended would be lost at the done.
    accepted=''
    while IFS= read -r gitpath; do
      [ -n "$gitpath" ] || continue
      repo="$(dirname "$gitpath")"
      # Nested checkouts -- submodules, and the legitimate .claude/worktrees/ trees
      # inside a repo -- are not separate repos: their refs live in the parent's
      # object store, so listing them double-counts the same commits. Every path
      # with prefix "P/" is contiguous in a lexicographic sort, so one test against
      # the last accepted repo drops the whole nested block.
      if [ -n "$accepted" ]; then
        case "$repo/" in "$accepted"/*) continue ;; esac
      fi
      _remember "$repo"
      accepted="$repo"
    done <<EOF
$(_find_git_dirs "$root")
EOF
  done
}

# _find_git_dirs <root> -- every .git under root, sorted. Prints nothing on failure and
# bumps SCAN_ERRORS instead of pretending the root was empty.
#
# -H is the fix for the worst fail-open in this file. Without it, find does not follow
# a SYMLINKED root, so `ln -s /Volumes/Data/devpro ~/devpro` -- or any root under macOS's
# symlinked /tmp -- made the whole scan return nothing while the guard above passed,
# because `[ ! -d "$root" ]` DOES follow symlinks. Reproduced: --report printed
# "no git repos found ... nothing was checked" and --verify exited 0 over a symlinked
# tree holding 8 repos, 6 with findings. -H follows only the path named on the command
# line, which is exactly the root, so nothing inside the tree is newly followed and the
# link-loop risk of -L is not taken on.
#
# find's stderr is captured rather than discarded: `2>/dev/null` is what let a bad
# -maxdepth argument look identical to an empty directory.
_find_git_dirs() {
  _fg_root="$1"
  _fg_err="${TMPDIR:-/tmp}/macboot-find.$$"
  _fg_rc=0
  find -H "$_fg_root" -maxdepth "$MACBOOT_REPO_DEPTH" -name .git \
    -not -path '*/.git/*' -not -path '*/node_modules/*' \
    -print 2>"$_fg_err" | LC_ALL=C sort || _fg_rc=$?
  # find exits non-zero on unreadable subdirectories too, which is a partial scan and
  # therefore still a reason not to trust a clean verdict.
  if [ "$_fg_rc" != 0 ] || [ -s "$_fg_err" ]; then
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
    warn "scanning $_fg_root was incomplete (find exit $_fg_rc):
     $(head -2 "$_fg_err" 2>/dev/null | sed 's/^/     /')"
  fi
  rm -f "$_fg_err"
}

# ---------------------------------------------------------------------------
# The four checks. Each appends to FINDINGS (fails the gate) or NOTES (worth
# saying, not worth blocking on); bash 3.2 cannot return three strings, so those
# two plus BUNDLE_ME are globals set per repo.
# ---------------------------------------------------------------------------

UNTRACKED_REPOS=0

_finding() { FINDINGS="${FINDINGS:+$FINDINGS; }$1"; }
_note() { NOTES="${NOTES:+$NOTES; }$1"; }

check_origin() {
  local repo url rc
  repo="$1"
  url="$(git -C "$repo" config --get remote.origin.url 2>/dev/null || true)"
  if [ -z "$url" ]; then
    _finding "no origin remote configured"
    BUNDLE_ME=1
    return 0
  fi
  rc=0
  # ssh's ConnectTimeout is a FRACTION of the overall deadline, not equal to it.
  #
  # Equal, ssh always expired first, so the poller's 124 branch below was effectively
  # unreachable for every ssh remote and the `*)` branch won instead -- which reads
  # "origin is configured but does not resolve", sets BUNDLE_ME=1, and prints a
  # paste-ready `gh repo create`. Verified against a routable blackhole with wifi off:
  # the tool advised creating a duplicate remote for a repo whose origin was perfectly
  # fine. Run it on a plane and it recommended that for every repo you own.
  #
  # Two thirds leaves the poller room to be the thing that fires on a slow network,
  # while a genuinely dead host still fails inside the budget. Minimum 2s so a small
  # MACBOOT_REMOTE_TIMEOUT cannot round down to an unusable 0 or 1.
  _co_ssh_timeout=$((MACBOOT_REMOTE_TIMEOUT * 2 / 3))
  [ "$_co_ssh_timeout" -ge 2 ] || _co_ssh_timeout=2
  _co_err="${TMPDIR:-/tmp}/macboot-lsremote.$$"

  # BatchMode, no askpass, no terminal prompt: without these an ssh remote whose
  # key is absent stops the whole scan on a passphrase prompt and an https remote
  # pops a credential dialog. A gate that blocks on input is a gate people skip.
  _timeout "$MACBOOT_REMOTE_TIMEOUT" \
    env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/true \
    GIT_SSH_COMMAND="ssh -oBatchMode=yes -oConnectTimeout=$_co_ssh_timeout" \
    git -C "$repo" ls-remote --exit-code origin 2>"$_co_err" || rc=$?

  case "$rc" in
    0) ;;
    # --exit-code answers 2 for "connected fine, the remote has no refs". The
    # server replied, so the remote exists; an empty origin is caught by the
    # branch check instead, where every local branch shows up as unpushed.
    2) _note "origin is reachable but holds no refs yet" ;;
    124) _finding "origin did not answer within ${MACBOOT_REMOTE_TIMEOUT}s ($url): offline, or gone" ;;
    *)
      # "The network is down" and "this remote no longer exists" demand opposite
      # actions, so they must not share a message. Transport-level failures are read off
      # ssh's own stderr rather than guessed from an exit status that is 255 for both a
      # dead host and a rejected key.
      if grep -qiE 'operation timed out|connection timed out|could not resolve|name or service not known|network is (unreachable|down)|no route to host|connection refused' \
        "$_co_err" 2>/dev/null; then
        _note "origin could not be reached from this network ($url): NOT judged, rerun online"
      else
        _finding "origin is configured but does not resolve ($url)"
        BUNDLE_ME=1
      fi
      ;;
  esac
  rm -f "$_co_err"
  return 0
}

check_stash() {
  local repo n
  repo="$1"
  n="$(git -C "$repo" stash list 2>/dev/null | wc -l | tr -d ' ' || true)"
  [ -n "$n" ] || n=0
  [ "$n" -eq 0 ] ||
    # Accurate about which escape routes exist. `git push` and `git clone` really do
    # not carry refs/stash -- but `git bundle create --all` DOES, verified with
    # `git bundle list-heads` on a fixture with one stash. Telling a user that the
    # rescue this very tool offers cannot save their stashes pushes them toward riskier
    # manual recovery, which is the opposite of the intent.
    _finding "$n stash(es): no push or clone carries them; --bundle does"
  return 0
}

check_branches() {
  local repo br up track no_up ahead gone unrelated
  repo="$1"
  no_up=0
  ahead=0
  gone=0
  unrelated=0
  while IFS='|' read -r br up track; do
    [ -n "$br" ] || continue
    if [ -z "$up" ]; then
      no_up=$((no_up + 1))
      continue
    fi
    case "$track" in
      *gone*)
        gone=$((gone + 1))
        continue
        ;;
      *ahead*) ahead=$((ahead + 1)) ;;
    esac
    # merge-base prints NOTHING and exits 1 when the two sides share no commit at
    # all, which is what a rewritten upstream looks like from here (the offchart
    # rename orphaned ~155 commits exactly this way). Code that substitutes that
    # empty output into another git command dies mid-scan; the empty result IS the
    # finding, so it is tested for rather than passed on.
    if [ -z "$(git -C "$repo" merge-base "$br" "$up" 2>/dev/null || true)" ]; then
      unrelated=$((unrelated + 1))
    fi
  done <<EOF
$(git -C "$repo" for-each-ref \
    --format='%(refname:short)|%(upstream:short)|%(upstream:track)' \
    refs/heads 2>/dev/null || true)
EOF

  [ "$no_up" -eq 0 ] || _finding "$no_up local branch(es) with no upstream"
  [ "$gone" -eq 0 ] || _finding "$gone branch(es) whose upstream is gone from the server"
  [ "$ahead" -eq 0 ] || _finding "$ahead branch(es) ahead of upstream"
  [ "$unrelated" -eq 0 ] ||
    _finding "$unrelated branch(es) share no commit with upstream (history was rewritten there)"
  return 0
}

check_worktrees() {
  local repo line wt
  repo="$1"
  while IFS= read -r line; do
    case "$line" in
      'worktree '*)
        wt="${line#worktree }"
        # A registered worktree whose directory is gone is exactly how the
        # /private/tmp checkout was lost: `git worktree list` still shows it and
        # its branch still exists here, but nobody looks. The commits are safe in
        # this repo's object store, so this is a note; the branch check above is
        # what judges whether they are pushed.
        [ -d "$wt" ] || _note "registered worktree gone from disk: $wt (git worktree prune)"
        ;;
    esac
  done <<EOF
$(git -C "$repo" worktree list --porcelain 2>/dev/null || true)
EOF
  return 0
}

check_dirty() {
  local repo n u wt wn
  repo="$1"
  n="$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ' || true)"
  [ -n "$n" ] || n=0
  [ "$n" -eq 0 ] || _finding "$n uncommitted change(s) to tracked files"

  # LINKED WORKTREES, each checked in its own right.
  #
  # A worktree shares the object store, so its COMMITS are reachable from here and
  # folding it into the main checkout is correct for those. Its UNCOMMITTED changes are
  # not: `git status` in the main checkout says nothing about them. Before this, a
  # sibling worktree and a .claude/worktrees/ tree each holding an edit to a tracked
  # file produced "1 of 2 repos are fully pushed with a clean tree", no finding, and
  # --verify 0 -- while `git status` in the sibling reported ` M a`. This tool's own
  # motivating incident was a lost worktree.
  #
  # `git worktree list --porcelain` prints a `worktree <path>` line per checkout, the
  # first being this one, so the tail is exactly the linked set.
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    [ "$wt" != "$repo" ] || continue
    [ -d "$wt" ] || continue
    wn="$(git -C "$wt" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ' || true)"
    [ -n "$wn" ] || wn=0
    [ "$wn" -eq 0 ] ||
      _finding "$wn uncommitted change(s) in linked worktree $(basename "$wt")"
  done <<EOF
$(git -C "$repo" worktree list --porcelain 2>/dev/null |
    sed -n 's/^worktree //p' || true)
EOF
  # Untracked files are counted, not reported per repo and never a finding: build
  # output, .venv and editor droppings live in every working tree, and a gate that
  # is permanently red teaches people to set MACBOOT_SKIP_CHECK=1 and stop reading.
  u="$(git -C "$repo" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ' || true)"
  [ -n "$u" ] || u=0
  [ "$u" -eq 0 ] || UNTRACKED_REPOS=$((UNTRACKED_REPOS + 1))
  return 0
}

# check_detached_and_tags <repo> -- the two ref shapes `refs/heads` does not cover.
#
# check_branches walks refs/heads only, so both of these were classified as "fully
# pushed with a clean tree" and --verify exited 0:
#
#   * DETACHED HEAD with a commit on it. `git checkout --detach && git commit` leaves a
#     commit on no branch at all, which is the single most common way a commit ends up
#     existing in exactly one place -- and it is invisible to every branch-based check.
#   * A LOCAL TAG on work that is not on the remote. `git push` does not carry tags, so
#     an annotated release tag can be the only record of what was built.
#
# Both tests are OFFLINE: "is this commit contained in any remote-tracking ref". That is
# the right question and it costs no network call. Its limit, stated rather than
# hidden: a tag whose commit IS pushed but whose tag ref is not gets no finding. The
# commit is safe and the label is recreatable, so it is a documentation loss rather than
# a data loss -- unlike everything else this tool reports.
check_detached_and_tags() {
  local repo head n_tags t
  repo="$1"

  # symbolic-ref fails exactly when HEAD is detached.
  if ! git -C "$repo" symbolic-ref -q HEAD >/dev/null 2>&1; then
    head="$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || true)"
    if [ -n "$head" ]; then
      if [ -z "$(git -C "$repo" branch -r --contains HEAD 2>/dev/null || true)" ]; then
        _finding "HEAD is detached at $head and that commit is on no remote branch"
      else
        _note "HEAD is detached at $head (already on a remote branch)"
      fi
    fi
  fi

  # One rev-list per repo rather than per tag: --tags asks for everything reachable from
  # any tag, --remotes excludes everything already on a remote, and --no-walk keeps it
  # to the tagged commits themselves instead of their whole history.
  n_tags="$(git -C "$repo" rev-list --no-walk --tags --not --remotes 2>/dev/null |
    wc -l | tr -d ' ' || true)"
  [ -n "$n_tags" ] || n_tags=0
  if [ "$n_tags" -gt 0 ]; then
    t="$(git -C "$repo" tag --points-at "$(git -C "$repo" rev-list --no-walk --tags --not --remotes 2>/dev/null |
      head -1)" 2>/dev/null | head -3 | tr '\n' ' ' || true)"
    _finding "$n_tags tag(s) point at commits on no remote branch (e.g. ${t:-unnamed})"
  fi
  return 0
}

check_repo() {
  local repo
  repo="$1"
  FINDINGS=''
  NOTES=''
  BUNDLE_ME=0
  # A .git *file* pointing into a worktree administration dir that was deleted
  # makes every later git call exit 128. Report it and carry on rather than
  # aborting the scan of the other 44 repos.
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    _finding "git cannot read this checkout (dangling worktree pointer, or a broken .git)"
    return 0
  fi
  if [ -z "$(git -C "$repo" for-each-ref --count=1 refs/ 2>/dev/null || true)" ]; then
    _note "no refs at all: initialised but never committed"
    return 0
  fi
  check_origin "$repo"
  check_stash "$repo"
  check_branches "$repo"
  check_detached_and_tags "$repo"
  check_worktrees "$repo"
  check_dirty "$repo"
  return 0
}

# ---------------------------------------------------------------------------
# Bundling. A bundle is the right rescue for a repo with no reachable remote: it
# needs no server, no account and no network, --all captures every ref in one
# file, and the file is a normal object you can copy to another disk.
#
# It DOES capture stashes. refs/stash lives under refs/, so `--all` includes it --
# verified with `git bundle list-heads` on a fixture holding one stash, which listed
# refs/stash alongside refs/heads/main. An earlier comment here claimed the opposite,
# and that claim mattered: a user told the only offered rescue cannot save their
# stashes goes looking for a riskier manual one.
#
# What a bundle does NOT carry: the working tree and the index. Uncommitted changes are
# reported separately by check_dirty and are not rescuable this way -- commit them
# first, on a throwaway branch if need be.
# ---------------------------------------------------------------------------

# _bundle_is_current <bundle> <repo> -- does this bundle already hold today's refs?
# Existence is not enough: a bundle written last week verifies happily while
# missing the commits you are wiping the disk for. Comparing ref lists is what
# lets a second --bundle run report changed=0 without lying.
_bundle_is_current() {
  local have want
  have="$(git -C "$2" bundle list-heads "$1" 2>/dev/null | grep -v ' HEAD$' | LC_ALL=C sort || true)"
  want="$(git -C "$2" show-ref 2>/dev/null | LC_ALL=C sort || true)"
  [ -n "$have" ] && [ "$have" = "$want" ]
}

bundle_repos() {
  local dir repo name target seen i rc out base parent attempt
  dir="$1"
  if [ "$BUNDLE_N" -eq 0 ]; then
    ok "no repo needs a bundle: every origin resolved"
    return 0
  fi
  [ -d "$dir" ] || run mkdir -p "$dir"

  seen=''
  i=0
  while [ "$i" -lt "$BUNDLE_N" ]; do
    repo="${BUNDLE_PATH[$i]}"
    i=$((i + 1))
    # Collisions are resolved by LOOPING until the name is free, not by one rename.
    #
    # Two roots can each hold a "wiki". The old code renamed the second to
    # <parent>-<repo> and never re-tested the result -- and <parent> is the *area*
    # level, which repeats across roots. Verified with three repos at <root>/area/wiki
    # under three different roots: it wrote wiki.bundle, area-wiki.bundle and
    # area-wiki.bundle, so the second repo's bundle was silently overwritten by the
    # third and `git bundle list-heads` on the survivor held only the third repo's sha.
    # The second repo's only copy of its commits was in no bundle at all, and the tool
    # printed "area-wiki.bundle written and verified" both times. In a tool whose whole
    # purpose is to be the last copy, overwriting one backup with another is the worst
    # bug available to it.
    #
    # The final fallback is a digest of the repo PATH rather than a counter: it is
    # unique by construction and stable across runs, so a re-run updates the same
    # bundle instead of shuffling names when the scan order changes.
    base="$(basename "$repo")"
    parent="$(basename "$(dirname "$repo")")"
    name="$base"
    attempt=1
    while :; do
      case " $seen " in
        *" $name "*) ;; # taken; fall through and try the next spelling
        *) break ;;
      esac
      attempt=$((attempt + 1))
      case "$attempt" in
        2) name="$parent-$base" ;;
        *) name="$base-$(printf '%s' "$repo" | shasum -a 256 | cut -c1-8)" ;;
      esac
    done
    seen="$seen $name"
    target="$dir/$name.bundle"

    if [ -f "$target" ] && _bundle_is_current "$target" "$repo"; then
      skip "$name.bundle -> already holds every current ref"
      continue
    fi

    rc=0
    # --quiet because git's own progress meter writes to stderr and would fight
    # the spinner for the same line.
    spin_start "bundling $name --all"
    run git -C "$repo" bundle create --quiet "$target" --all || rc=$?
    spin_stop
    if [ "$rc" != 0 ]; then
      warn "$name: bundle create exited $rc, nothing was captured for this repo"
      BUNDLE_FAIL=$((BUNDLE_FAIL + 1))
      continue
    fi
    [ "$DRY_RUN" = "1" ] && continue
    # Refusing to claim success without verify is the point of this mode: an
    # interrupted or truncated bundle is a file of the right name and size that
    # restores nothing, and you find that out when the original is gone.
    if out="$(git -C "$repo" bundle verify "$target" 2>&1)"; then
      ok "$name.bundle written and verified"
    else
      warn "$name.bundle does NOT verify -- treat it as no backup:
     $(printf '%s' "$out" | head -3)"
      BUNDLE_FAIL=$((BUNDLE_FAIL + 1))
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------

report() {
  local repo findings notes n clean i
  FAIL_N=0
  BUNDLE_N=0
  BUNDLE_PATH=()
  clean=0
  i=0
  while [ "$i" -lt "$REPO_N" ]; do
    repo="${REPO_PATH[$i]}"
    findings="${REPO_FIND[$i]}"
    notes="${REPO_NOTE[$i]}"
    if [ -n "$findings" ]; then
      FAIL_N=$((FAIL_N + 1))
      # rev-list --count --all is what makes the report worth reading: "31
      # branches" is abstract, "126 commits that exist here only" is not.
      n="$(git -C "$repo" rev-list --count --all 2>/dev/null || echo '?')"
      warn "$(basename "$repo") ($n commit(s)) -- $findings"
      # The machine-readable copy goes to stdout (common.sh keeps narration on
      # stderr) so the gate reads a list instead of parsing colour codes back out
      # of a transcript -- but only when stdout is redirected. Emitting it to a
      # terminal too would print every finding twice to the human who asked once.
      [ -t 1 ] || printf '%s\t%s\n' "$repo" "$findings"
    else
      clean=$((clean + 1))
    fi
    [ -z "$notes" ] || log "$(basename "$repo"): $notes"
    if [ "${REPO_BUNDLE[$i]}" = "1" ]; then
      BUNDLE_PATH[BUNDLE_N]="$repo"
      BUNDLE_N=$((BUNDLE_N + 1))
    fi
    i=$((i + 1))
  done
  ok "$clean of $REPO_N repos are fully pushed with a clean tree"
  [ "$UNTRACKED_REPOS" -eq 0 ] ||
    log "$UNTRACKED_REPOS repo(s) also hold untracked files (ignored files excluded); not a finding"
}

# Creating a remote is outward-facing -- it picks an owner, a visibility and a name
# that outlive this run -- so the command is printed and never executed, in every mode.
print_gh_hint() {
  local i
  [ "$BUNDLE_N" -gt 0 ] || return 0
  log "$BUNDLE_N repo(s) have no working origin. NOT RUNNING any of the following; that call is yours:"
  i=0
  while [ "$i" -lt "$BUNDLE_N" ]; do
    printf '    gh repo create <owner>/%s --private --source %s --push\n' \
      "$(basename "${BUNDLE_PATH[$i]}")" "${BUNDLE_PATH[$i]}" >&2
    i=$((i + 1))
  done
  log "or capture them offline first: check-unpushed.sh --bundle <dir-on-another-disk>"
}

main() {
  local i repo
  MODE=report
  BUNDLE_DIR=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --verify) MODE=verify ;;
      --report) MODE=report ;;
      --bundle)
        MODE=bundle
        [ $# -ge 2 ] || die "--bundle needs a directory"
        BUNDLE_DIR="$2"
        shift
        ;;
      --bundle=*)
        MODE=bundle
        BUNDLE_DIR="${1#--bundle=}"
        [ -n "$BUNDLE_DIR" ] || die "--bundle needs a directory"
        ;;
      --dry-run) DRY_RUN=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
  done
  has git || die "git is not on PATH; run scripts/00-preflight.sh (the Xcode CLT ship git)"

  step "Scanning $MACBOOT_REPO_ROOTS"
  discover_repos
  if [ "$REPO_N" -eq 0 ]; then
    warn "no git repos found under $MACBOOT_REPO_ROOTS, so nothing was checked.
     If that is wrong they sit deeper than MACBOOT_REPO_DEPTH=$MACBOOT_REPO_DEPTH."
    summary "check-unpushed"
    # --verify must NOT pass here. Scanning zero repos is not a clean bill of health,
    # and this exact shape was the vacuous half of the CI job: a fixture that stopped
    # building repos, a mistyped root, a symlinked root, a bad -maxdepth -- all produced
    # "nothing was checked" plus exit 0, i.e. the gate certifying a machine it never
    # looked at. --report still exits 0, because reporting is not gating.
    [ "$MODE" != verify ] ||
      die "scanned 0 repositories, so this is not a clean result -- it is no result.
     Check MACBOOT_REPO_ROOTS ($MACBOOT_REPO_ROOTS) and MACBOOT_REPO_DEPTH."
    return 0
  fi
  ok "$REPO_N repos ($FOLDED extra checkout(s) of the same repository folded in)"

  step "Checking origin, stashes, branch upstreams and working trees"
  i=0
  while [ "$i" -lt "$REPO_N" ]; do
    repo="${REPO_PATH[$i]}"
    if [ "$REPO_N" -gt 1 ]; then
      progress "$((i + 1))" "$REPO_N" "$(basename "$repo")"
    fi
    check_repo "$repo"
    REPO_FIND[i]="$FINDINGS"
    REPO_NOTE[i]="$NOTES"
    REPO_BUNDLE[i]="$BUNDLE_ME"
    i=$((i + 1))
  done

  step "Report"
  report
  print_gh_hint

  BUNDLE_FAIL=0
  if [ "$MODE" = bundle ]; then
    step "Bundling repos with no reachable origin into $BUNDLE_DIR"
    bundle_repos "$BUNDLE_DIR"
  fi

  summary "check-unpushed"
  case "$MODE" in
    verify)
      [ "$FAIL_N" -eq 0 ] ||
        die "$FAIL_N repo(s) hold work that exists in exactly one place (listed above)"
      # A partial scan cannot produce a clean verdict. An unreadable directory, a
      # missing root or a find that errored all leave repositories unexamined, and this
      # tool is only worth having if a green result means "I looked everywhere".
      [ "$SCAN_ERRORS" -eq 0 ] ||
        die "$SCAN_ERRORS root(s) could not be scanned completely (warnings above), so
     no repository under them was examined. Fix that before trusting this result."
      ;;
    bundle)
      [ "$BUNDLE_FAIL" -eq 0 ] ||
        die "$BUNDLE_FAIL bundle(s) could not be verified; do not treat $BUNDLE_DIR as a backup"
      ;;
  esac
  return 0
}

main "$@"
