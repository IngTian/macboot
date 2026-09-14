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
  # Normalise through the filesystem before comparing. git answers this question in two
  # different spellings: the MAIN checkout gets the RELATIVE `.git`, which then inherits
  # whatever path the caller walked in on, while a LINKED worktree gets an ABSOLUTE
  # realpath. Any symlink component in the root makes those two strings differ, so the
  # fold silently failed and one repository was scanned, reported and bundled twice.
  # Measured on the same fixture: root `/var/folders/.../r3` -> "2 repos (0 folded)",
  # root `/private/var/folders/.../r3` -> "1 repos (1 folded)". macOS's /tmp and /var are
  # both symlinks and a symlinked root is the case `-H` in _find_git_dirs exists to
  # support, so this is the normal path, not an exotic one. It also repairs the
  # "main checkout wins" test below, which compares against an already-realpath'd
  # --absolute-git-dir.
  common="$(cd "$common" 2>/dev/null && pwd -P || printf '%s' "$common")"
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
  local roots root repo gitpath _dr_out
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
    # which would otherwise report every submodule a second time.
    #
    # The paths come back through a FILE, not a command substitution. Written as
    # `done <<EOF / $(_find_git_dirs "$root") / EOF` the finder ran in a SUBSHELL, so
    # its SCAN_ERRORS bump and its warn() counter increment were both discarded at the
    # closing paren: the "a partial scan cannot produce a clean verdict" gate in main()
    # read 0 forever, and --verify exited 0 over a tree it could not finish walking --
    # the same fail-open class `-H` was added to close, one level up. Only the warning
    # TEXT survived, which is why a transcript looked correct. Reproduced with one
    # chmod-000 directory beside a readable repo: warning on screen, "0 warnings" in the
    # summary box, exit 0, and the repo behind it never opened. Reading from a file also
    # keeps the `while` loop in THIS shell, which is what the heredoc was for.
    _dr_out="${TMPDIR:-/tmp}/macboot-repos.$$"
    if ! _find_git_dirs "$root" "$_dr_out"; then
      SCAN_ERRORS=$((SCAN_ERRORS + 1))
    fi
    while IFS= read -r gitpath; do
      [ -n "$gitpath" ] || continue
      repo="$(dirname "$gitpath")"
      # No path-prefix prune here, on purpose. There used to be one, dropping every
      # .git under an already-accepted repo as "nested, so its refs live in the
      # parent's object store". That is true of a linked worktree and FALSE of a
      # submodule -- whose objects live in <super>/.git/modules/<name> -- and false of
      # an independent clone dropped inside another project's tree. Both were deleted
      # from the scan before any check ran: a submodule one commit ahead of its own
      # origin gave "1 of 1 repos are fully pushed with a clean tree" and exit 0, and
      # `git -C <super> cat-file -e <sub HEAD>` confirms the commit is in no object
      # store but the submodule's own. _remember folds by `git rev-parse
      # --git-common-dir`, which is the identity test that actually distinguishes the
      # two: it still folds worktrees and it keeps submodules.
      _remember "$repo"
    done <"$_dr_out"
    rm -f "$_dr_out"
  done
}

# _find_git_dirs <root> <outfile> -- every .git under root, sorted, into <outfile>.
# Returns non-zero when the walk was incomplete, so the CALLER can count it.
#
# The counting deliberately lives in discover_repos rather than here: this function used
# to bump SCAN_ERRORS itself, but it was invoked inside a command substitution, so the
# increment happened in a subshell and never reached the gate. Writing to a file the
# caller names is what puts both the loop and the counter in one shell.
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
  _fg_out="$2"
  _fg_err="${TMPDIR:-/tmp}/macboot-find.$$"
  _fg_rc=0
  find -H "$_fg_root" -maxdepth "$MACBOOT_REPO_DEPTH" -name .git \
    -not -path '*/.git/*' -not -path '*/node_modules/*' \
    -print 2>"$_fg_err" | LC_ALL=C sort >"$_fg_out" || _fg_rc=$?
  # find exits non-zero on unreadable subdirectories too, which is a partial scan and
  # therefore still a reason not to trust a clean verdict.
  if [ "$_fg_rc" != 0 ] || [ -s "$_fg_err" ]; then
    warn "scanning $_fg_root was incomplete (find exit $_fg_rc):
     $(head -2 "$_fg_err" 2>/dev/null | sed 's/^/     /')"
    rm -f "$_fg_err"
    return 1
  fi
  rm -f "$_fg_err"
  return 0
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
    # --exit-code answers 2 for "connected fine, the remote has no refs".
    #
    # That is only harmless when this repo has no commits either. It used to be a bare
    # note, on the reasoning that "an empty origin is caught by the branch check instead"
    # -- but the branch check reads refs/remotes/origin/*, which is a LOCAL CACHE that
    # survives the server being emptied. Reproduced: push to a bare origin, delete
    # refs/heads/main from it, and `ls-remote` advertises zero refs while
    # `branch -vv` still says "[origin/main]" with nothing ahead, so every check cleared
    # the repo and --verify exited 0 for a remote that provably holds none of its
    # commits. That is the first failure this file's header names, so the server's answer
    # has to win over the cache. rev-list guards the genuinely-empty-both-ends case.
    2)
      if [ -n "$(git -C "$repo" rev-list -n1 --all 2>/dev/null || true)" ]; then
        _finding "origin answered but holds NO refs ($url): the server has none of your commits"
        BUNDLE_ME=1
      else
        _note "origin is reachable but holds no refs yet"
      fi
      ;;
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
    # Two spellings of "this is the main checkout, skip it": $wt comes from `worktree
    # list --porcelain`, which always prints a REALPATH, while $repo is the path find(1)
    # walked in on. Under a symlinked root (macOS /tmp and /var are symlinks) they differ,
    # so the main checkout was re-reported as one of its own linked worktrees and a single
    # dirty file produced two findings. --show-toplevel gives the realpath spelling.
    [ "$wt" != "$repo" ] &&
      [ "$wt" != "$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || true)" ] ||
      continue
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
# the right question and it costs no network call.
#
# KNOWN REMAINING GAP, stated rather than hidden: a tag whose COMMIT is pushed but whose
# TAG REF was never pushed gets no finding, because `--not --remotes` subtracts that
# commit. For a lightweight tag that is genuinely just a recreatable label. For an
# ANNOTATED tag it is not -- the ref points at a tag OBJECT carrying tagger, date and
# message, and `git push` does not carry tags, so that object can exist on exactly one
# disk while this tool prints "fully pushed with a clean tree" and exits 0. Reproduced:
# `git tag -a v3 -m rel` on an already-pushed commit, then `cat-file -e` in the bare
# origin reports the tag object ABSENT. Closing it needs one `ls-remote --tags` per repo
# (offline it is not decidable), which is a network call this function deliberately does
# not make -- so it is a gap, not a decision that the content does not matter.
check_detached_and_tags() {
  local repo head n_tags t wt
  repo="$1"

  # Once per CHECKOUT, not once per repo. _remember deliberately folds a linked worktree
  # into its main checkout -- correct for commits, which share the object store -- so a
  # detached HEAD in a worktree was never asked about at all: this ran only on the
  # surviving path. Reproduced with `worktree add --detach` plus one commit, both nested
  # and sibling: "1 of 1 repos are fully pushed with a clean tree", exit 0, for a commit
  # reachable from nothing but that worktree's HEAD. The tool's own motivating incident
  # was a lost worktree, so this is the last place it should have a blind spot. The main
  # checkout is the first line of `worktree list --porcelain`, so it is still covered.
  while IFS= read -r wt; do
    [ -n "$wt" ] && [ -d "$wt" ] || continue
    # symbolic-ref fails exactly when HEAD is detached.
    git -C "$wt" symbolic-ref -q HEAD >/dev/null 2>&1 && continue
    head="$(git -C "$wt" rev-parse --short HEAD 2>/dev/null || true)"
    [ -n "$head" ] || continue
    if [ -z "$(git -C "$wt" branch -r --contains HEAD 2>/dev/null || true)" ]; then
      _finding "HEAD is detached at $head in $(basename "$wt") and that commit is on no remote branch"
    else
      _note "HEAD is detached at $head in $(basename "$wt") (already on a remote branch)"
    fi
  done <<EOF
$(git -C "$repo" worktree list --porcelain 2>/dev/null |
    sed -n 's/^worktree //p' || true)
EOF

  # `--not --remotes` subtracts nothing when there are no remote-tracking refs, so with no
  # origin at all EVERY tag in the repo reads as unpushed -- arithmetically guaranteed,
  # and a third finding on a repo that check_origin has already condemned twice. Verified
  # on a fixture with 3 tags and no remote: "no origin remote configured; 1 local
  # branch(es) with no upstream; 3 tag(s) point at commits on no remote branch". Nothing
  # is lost by staying quiet: check_origin's `_finding "no origin remote configured"` at
  # the top of the file is unconditional, so --verify still refuses, and `bundle create
  # --all` demonstrably carries refs/tags (checked with `bundle list-heads`).
  #
  # Keyed on the origin URL, NOT on refs/remotes being empty. The refs/remotes test is
  # the tempting version and it is strictly weaker: it would also silence a repo whose
  # origin is configured and reachable but never fetched, where the tags may be genuinely
  # unpushed and check_origin stays silent. Because the URL is exactly the condition under
  # which check_origin has already produced a finding, this can never turn a red green.
  if [ -z "$(git -C "$repo" config --get remote.origin.url 2>/dev/null || true)" ]; then
    return 0
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
  # ANY finding makes the repo worth bundling, not just a missing or dead origin.
  #
  # BUNDLE_ME used to be set only by check_origin, so the common retirement case -- a
  # repo with a live GitHub origin plus local-only stashes, local tags or a detached-HEAD
  # experiment -- got "no repo needs a bundle: every origin resolved", exit 0, and no
  # destination directory created at all. check_stash's own message tells the user
  # "--bundle does" carry stashes, so the tool advertised a rescue and then, asked for it,
  # printed a green all-clear and wrote nothing. Bundling a repo that has findings is
  # never harmful, and _bundle_is_current still keeps a second run at changed=0.
  [ -z "$FINDINGS" ] || BUNDLE_ME=1
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
#
# HEAD is part of the comparison, not filtered out of it. `--all` records HEAD, and a
# DETACHED HEAD is the one ref whose commit is on no branch -- exactly what this tool
# reports as work existing in one place only. Dropping it meant a detached commit made
# after the first --bundle was in no bundle, while the same run printed "already holds
# every current ref" and exited 0: the tool asserted a backup contained a commit it had
# just finished warning was unique. `show-ref --head` is the matching spelling, and for a
# non-detached repo both sides are byte-identical, so changed=0 on a re-run is preserved.
_bundle_is_current() {
  local have want
  have="$(git -C "$2" bundle list-heads "$1" 2>/dev/null | LC_ALL=C sort || true)"
  want="$(git -C "$2" show-ref --head 2>/dev/null | LC_ALL=C sort || true)"
  [ -n "$have" ] && [ "$have" = "$want" ]
}

# _bundle_restores <bundle> -- does the pack actually read back?
#
# `git bundle verify` reads only the bundle HEADER: the prerequisite commits and the ref
# list. Measured: it exits 0 and prints "The bundle records a complete history" for a
# bundle truncated to 60% AND for one with a single flipped byte in the pack, while
# `git clone` of the same file dies with "early EOF / index-pack died". So verify alone
# cannot support the claim this mode exists to make. Unbundling into a throwaway bare
# repo walks every object, which is the cheapest check that actually reads the pack.
_bundle_restores() {
  _br_tmp="$(mktemp -d)" || return 1
  _br_rc=0
  if ! git init -q --bare "$_br_tmp/probe" >/dev/null 2>&1; then
    _br_rc=1
  elif ! git -C "$_br_tmp/probe" bundle unbundle "$1" >/dev/null 2>&1; then
    _br_rc=1
  fi
  rm -rf "$_br_tmp"
  return "$_br_rc"
}

bundle_repos() {
  local dir repo name target seen key i rc out base parent attempt
  dir="$1"
  if [ "$BUNDLE_N" -eq 0 ]; then
    ok "no repo needs a bundle: nothing found that a bundle would rescue"
    return 0
  fi
  [ -d "$dir" ] || run mkdir -p "$dir"
  # ABSOLUTE from here on. Every write below is `git -C "$repo" bundle create <target>`,
  # and git resolves a relative target inside the REPO, not the caller's cwd. So
  # `cd /Volumes/Backup && check-unpushed.sh --bundle .` -- the most natural way to type
  # it -- wrote every bundle into the repo about to be erased, left the external drive
  # empty, and printed "written and verified" for each one. _bundle_is_current stat'd yet
  # a third path (relative to the cwd), so the "already current" skip never matched
  # either and every re-run re-bundled. Skipped under DRY_RUN because the mkdir above is
  # skipped there too, so the directory may legitimately not exist yet.
  if [ "$DRY_RUN" != "1" ]; then
    dir="$(cd "$dir" 2>/dev/null && pwd)" ||
      die "--bundle destination does not exist and could not be created: $1"
  fi

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
      # The taken-name test folds case, because the DESTINATION filesystem does.
      # APFS is case-insensitive by default, so `Wiki` and `wiki` are one path: a
      # case-sensitive test matched neither, both resolved to the same target, and the
      # second `bundle create` silently overwrote the first repo's only backup while the
      # tool printed "written and verified" twice and exited 0. Verified on this host
      # (`touch Foo; ls foo` resolves) with ~/devpro/ea/Wiki beside ~/devpro/notes/wiki,
      # an ordinary layout. It also stopped the "already holds every current ref" skip
      # from ever matching, so every re-run flipped the survivor between the two repos.
      # bash 3.2 has no ${name,,}, hence tr.
      key="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
      case " $seen " in
        *" $key "*) ;; # taken; fall through and try the next spelling
        *) break ;;
      esac
      attempt=$((attempt + 1))
      case "$attempt" in
        2) name="$parent-$base" ;;
        *) name="$base-$(printf '%s' "$repo" | shasum -a 256 | cut -c1-8)" ;;
      esac
    done
    seen="$seen $key"
    target="$dir/$name.bundle"

    if [ -f "$target" ] && _bundle_is_current "$target" "$repo"; then
      # The skip path has to READ the file, not just compare its ref list. Re-running
      # --bundle is the natural "is my backup still good?" check before erasing a
      # machine, and matching refs say nothing about the pack behind them: a bundle
      # corrupted after it was written (a bad copy onto the destination drive, a flaky
      # enclosure, a half-synced cloud folder) still lists every ref. Without this the
      # tool answered "already holds every current ref", exited 0, and the file could
      # not be cloned.
      if [ "$DRY_RUN" = "1" ] || _bundle_restores "$target"; then
        skip "$name.bundle -> already holds every current ref"
        continue
      fi
      warn "$name.bundle lists every current ref but does NOT unbundle, so it restores
     nothing -- rewriting it"
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
    if ! out="$(git -C "$repo" bundle verify "$target" 2>&1)"; then
      warn "$name.bundle does NOT verify -- treat it as no backup:
     $(printf '%s' "$out" | head -3)"
      BUNDLE_FAIL=$((BUNDLE_FAIL + 1))
    elif ! _bundle_restores "$target"; then
      # Two separate failures. `bundle verify` passing and the pack being unreadable is
      # the dangerous combination, because it is the one that prints a green tick.
      warn "$name.bundle passes 'bundle verify' but does NOT unbundle, so it restores
     nothing -- treat it as no backup. verify reads only the header; the pack itself
     is truncated or corrupt."
      BUNDLE_FAIL=$((BUNDLE_FAIL + 1))
    else
      ok "$name.bundle written and verified"
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

# _mode_once <mode> -- set MODE, refusing a SECOND mode flag.
#
# The arms below used to assign MODE unconditionally, so two mode flags collapsed to
# whichever came last and the other was silently dropped -- and only one of them is a
# gate. `--verify --bundle DIR`, the obvious "check and rescue in one pass", printed its
# findings and then exited 0, because main()'s closing `case` has one arm per mode and
# only consulted BUNDLE_FAIL. The reverse order, `--bundle DIR --verify`, silently
# created no bundle and no destination directory at all. usage() has always documented
# the three as alternatives, so this is unvalidated input at a trust boundary: refuse it
# rather than pick one. Repeating the SAME flag is harmless and stays allowed.
_mode_once() {
  [ -z "$MODE_SET" ] || [ "$MODE_SET" = "$1" ] ||
    die "--report, --verify and --bundle are mutually exclusive (got --$MODE_SET and
     --$1). Run the tool twice: --bundle <dir> to capture, then --verify to gate."
  MODE="$1"
  MODE_SET="$1"
}

main() {
  local i repo
  MODE=report
  MODE_SET=''
  BUNDLE_DIR=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --verify) _mode_once verify ;;
      --report) _mode_once report ;;
      --bundle)
        _mode_once bundle
        [ $# -ge 2 ] || die "--bundle needs a directory"
        BUNDLE_DIR="$2"
        shift
        ;;
      --bundle=*)
        _mode_once bundle
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
    # --bundle is held to the same standard: exiting 0 having written no bundle is how
    # `check-unpushed.sh --bundle /Volumes/Backup && diskutil eraseDisk ...` erases a
    # disk on the strength of a backup that was never made.
    case "$MODE" in
      verify | bundle)
        die "scanned 0 repositories, so this is not a clean result -- it is no result.
     Check MACBOOT_REPO_ROOTS ($MACBOOT_REPO_ROOTS) and MACBOOT_REPO_DEPTH."
        ;;
    esac
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
    step "Bundling repos with findings into $BUNDLE_DIR"
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
      # Same doctrine as verify, for the same reason. A bundle set built from a partial
      # scan is not a backup of this disk, only of the part of it that happened to be
      # readable -- and the two warnings that say so scroll past above a green closing
      # box. Reproduced: one chmod-000 directory hiding a repo whose commit existed
      # nowhere else, and `--bundle` still exited 0.
      [ "$SCAN_ERRORS" -eq 0 ] ||
        die "$SCAN_ERRORS root(s) could not be scanned completely (warnings above), so
     $BUNDLE_DIR does not cover every repository on this disk."
      ;;
  esac
  return 0
}

main "$@"
