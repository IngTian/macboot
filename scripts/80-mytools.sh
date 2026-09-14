#!/usr/bin/env bash
# 80-mytools.sh -- build the author's own tools from source. OPT-IN.
#
# Nobody else's bootstrap should clone four of my repos, so each one is asked for
# separately and every answer defaults to no. With no terminal to ask at -- `curl | bash`,
# CI, the test suite -- or under --yes, nothing is built at all. bootstrap.sh globs every
# scripts/NN-*.sh, so that gate has to live here rather than in a list that can drift.
#
# Every repo is cloned over HTTPS, never SSH: key custody is the one problem this
# bootstrap deliberately does not solve (spec, "Left unsolved"), and a fresh Mac
# has no key at all. The single private repo is the exception and is probed first.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

#: Where checkouts land. Real working copies you may want to hack on, not build
#: scratch -- they are kept, never deleted.
MACBOOT_SRC="$MACBOOT_HOME/src"

#: 1 = actually do it.
MACBOOT_MYTOOLS="${MACBOOT_MYTOOLS:-0}"

#: Where single binaries land. Already on PATH for non-interactive shells (see the
#: symlink arrangement in 40-node.sh), which is why it is used rather than
#: /usr/local/bin: no sudo, and it survives a Homebrew reinstall.
BIN_DIR="$MACBOOT_HOME/.local/bin"

#: uv installs tools under $HOME by default, which would make a scratch-home run
#: write into the real home and leave a `day` on the tester's PATH. Both variables
#: resolve to uv's own defaults when MACBOOT_HOME is $HOME, so this costs nothing
#: in the normal case and makes the double-run test honest.
UV_TOOL_DIR="$MACBOOT_HOME/.local/share/uv/tools"
UV_TOOL_BIN_DIR="$BIN_DIR"
export UV_TOOL_DIR UV_TOOL_BIN_DIR

#: Set by clone_or_pull: fresh | updated | current. Read by the build steps to
#: decide whether a rebuild is needed at all.
CLONE_STATE=''

usage() {
  cat <<'EOF'
Usage: 80-mytools.sh [--force] [--dry-run]

Clones or fast-forwards my own tools into ~/src and builds
each one: witness (Go), daylogs (Python/uv), manifold (Swift screensaver) and
trading-desk (private -- skipped with a message when you cannot see it).

Each tool is asked for separately and defaults to NO. --force (or MACBOOT_MYTOOLS=1,
which `make mytools` sets) answers yes to all of them without asking. With no
terminal to ask at, or under --yes, nothing is built.

A missing toolchain (go, uv, swiftc) warns and skips that tool; it never fails the run.
EOF
}

# ---------------------------------------------------------------------------

# clone_or_pull <clone url> <label> <dir>
#
# Never re-clones over an existing checkout. Three cases:
#   .git present  -> fast-forward only. --ff-only because a merge or rebase here
#                    could leave someone's own commits in a conflicted tree that
#                    a bootstrap has no business creating; a failed pull is a warn
#                    and we build whatever is on disk.
#   nothing there -> clone.
#   a non-git dir -> leave it completely alone. That directory is somebody's work
#                    and this script cannot tell it apart from a stale unpack.
clone_or_pull() {
  url="$1"
  label="$2"
  dir="$3"
  CLONE_STATE=current

  if [ -d "$dir/.git" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      printf '%s would%s git -C %s pull --ff-only\n' "$_C_DIM" "$_C_RESET" "$dir" >&2
      return 0
    fi
    # NOT `run git pull`: run() increments the changed counter whenever it executes,
    # so an up-to-date checkout counted as a change and the module closed with
    # changed=3 on a second `make mytools` while printing "already current" for every
    # repo. That contradicts the whole idempotency claim, whose only observable form is
    # this counter. The counter is bumped below, once, and only when HEAD actually
    # moved. GIT_TERMINAL_PROMPT=0 so an expired credential fails fast instead of
    # blocking on an invisible username prompt.
    before="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo none)"
    if GIT_TERMINAL_PROMPT=0 git -C "$dir" pull --ff-only --quiet; then
      after="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo none)"
      if [ "$before" = "$after" ]; then
        skip "$label -> checkout already current"
      else
        MACBOOT_CHANGED=$((MACBOOT_CHANGED + 1))
        CLONE_STATE=updated
        ok "$label -> fast-forwarded to $(printf '%.7s' "$after")"
      fi
    else
      warn "$label -> 'git pull --ff-only' failed (local commits, a dirty tree, or no
     credential); building what is on disk"
    fi
    return 0
  fi

  if [ -e "$dir" ]; then
    warn "$label -> $dir exists and is not a git checkout; leaving it untouched"
    return 1
  fi

  run mkdir -p "$(dirname "$dir")"
  # No spinner, and GIT_TERMINAL_PROMPT=0.
  #
  # `git clone` over HTTPS for a repo it cannot read PROMPTS for a username and blocks
  # forever. That is reachable today: tool_trading_desk picks the https URL whenever
  # `gh repo view` succeeds, but gh's token lives in gh's own config, so a user
  # authenticated via GH_TOKEN or `gh auth login --with-token` without
  # `gh auth setup-git` has gh access and no git credential. It also becomes the
  # default path for the three public repos the moment one is renamed or made private.
  # The spinner made it worse: redrawing stderr every 0.1s painted over git's question,
  # so the user watched an eternal "cloning" with no visible prompt. The probe above
  # was fenced against exactly this and the clone was not.
  #
  # With prompts disabled git fails immediately with a readable error, which the warn
  # below turns into an actionable line instead of a hang. A passphrase prompt from ssh
  # is still possible and still wanted -- which is the other reason the spinner is gone.
  log "cloning $label"
  if run env GIT_TERMINAL_PROMPT=0 git clone --quiet "$url" "$dir"; then
    CLONE_STATE=fresh
    ok "$label -> cloned into $dir"
    return 0
  fi
  warn "$label -> clone failed; skipping the build. If this is a private repo, run
     'gh auth setup-git' so git can use your gh credential."
  return 1
}

# need <command> <tool> <where it comes from> -- a missing toolchain warns and
# skips one tool. Never a die: this module is opt-in extras, and a machine without
# `swiftc` is still a perfectly bootstrapped machine.
need() {
  if has "$1"; then
    return 0
  fi
  warn "$2 -> needs $1, which comes from $3; skipping"
  return 1
}

# have_checkout <dir> -- is there a tree to build in?
#
# Says yes in a dry run even though the clone only printed. Deliberate: a dry-run
# transcript that stopped at "would clone" would never show the compile and
# install commands, which is most of what someone reads a plan for. The build
# steps below therefore have to tolerate a directory that is not there, which is
# why each one asks before touching a path.
have_checkout() {
  if [ -d "$1" ] || [ "$DRY_RUN" = "1" ]; then
    return 0
  fi
  warn "$1 is not there after clone/pull; skipping its build"
  return 1
}

# uv_tool_install <dir> <uv tool name>
#
# `uv tool install` on an already-installed tool is a no-op WITHOUT --force, so a
# pulled fix would silently never land; with --force it reinstalls every run and
# the changed counter stops meaning anything. So: force only when the checkout
# actually moved.
uv_tool_install() {
  dir="$1"
  tool="$2"
  rc=0
  # In a dry run, describe and return: `uv tool list` creates ~/.cache/uv (measured),
  # which is the same cache 30-python.sh already guards a probe against, and --dry-run
  # must write nothing. Nothing below it would run anyway, since run() is inert there.
  if [ "$DRY_RUN" = "1" ]; then
    log "would uv tool install $dir (--force if the checkout moved) -> $UV_TOOL_BIN_DIR"
    return 0
  fi
  # Colour forced OFF for this one call, and the `^` anchor kept. With FORCE_COLOR or
  # CLICOLOR_FORCE set in the environment -- ordinary on a developer's machine -- uv wraps
  # the tool name in ANSI, so `^$tool ` never matched, every run took the --force branch,
  # and a second run reported changed=2 instead of 0. Suppressing the colour at the source
  # is what keeps the anchor: dropping it instead would let `logs` match `daylogs `.
  if env -u FORCE_COLOR -u CLICOLOR_FORCE NO_COLOR=1 uv tool list 2>/dev/null |
    grep -q "^$tool "; then
    if [ "$CLONE_STATE" = "current" ]; then
      skip "$tool -> already installed, checkout unchanged"
      return 0
    fi
    run uv tool install --force "$dir" || rc=$?
  else
    run uv tool install "$dir" || rc=$?
  fi
  # A failed install of one of my own tools is a warn, never a die: the module is
  # opt-in extras and the machine is still perfectly usable without them.
  if [ "$rc" = 0 ]; then
    ok "$tool -> installed into $UV_TOOL_BIN_DIR"
  else
    warn "$tool -> 'uv tool install' exited $rc; run it by hand in $dir"
  fi
}

# ---------------------------------------------------------------------------

tool_witness() {
  dir="$MACBOOT_SRC/witness"
  need go witness 10-brew.sh || return 0
  clone_or_pull https://github.com/IngTian/witness.git witness "$dir" || return 0
  have_checkout "$dir" || return 0

  # The Makefile names the binary after the target platform, so ask go rather than
  # hardcoding darwin-arm64 and breaking on an Intel Mac.
  #
  # Guarded, and inside an `if` so `set -e` is suspended. As a bare assignment a failing
  # `go env` killed the module instantly: on any machine with a shimmed-but-broken Go
  # (goenv or asdf pointing at a version a cleanup deleted -- true on THIS machine, where
  # `go env` prints "cannot find GOROOT directory: ~/.goenv/versions/1.25.1" and exits 2)
  # `make mytools-plan` ended right after a green "witness -> cloned" tick, with no warn,
  # no die and no summary box, and daylogs/manifold/trading-desk silently never ran.
  # `go env` also writes go's telemetry counter file into ~/Library/Application Support/go
  # in a dry run, which is a --dry-run purity violation on its own; the value is only used
  # for a "would link" line there, so skip the probe entirely.
  if [ "$DRY_RUN" = "1" ]; then
    # Named, not resolved. Nothing is built in a dry run, so the only consumer is the
    # "would link" line below -- and running the probe would write go's telemetry counter
    # into ~/Library/Application Support/go, which --dry-run promises not to do. The rest
    # of this function still runs, so the transcript keeps its "would make" line.
    bin="$dir/bin/witness-<goos>-<goarch>"
  elif ! goos="$(go env GOOS 2>/dev/null)" || ! goarch="$(go env GOARCH 2>/dev/null)" ||
    [ -z "$goos" ] || [ -z "$goarch" ]; then
    warn "witness -> 'go' is on PATH but 'go env' failed (a broken goenv/asdf shim?);
     skipping. Check 'go env GOOS' by hand, then re-run --only 80-mytools."
    return 0
  else
    bin="$dir/bin/witness-$goos-$goarch"
  fi

  # `make install` is NOT used on purpose: it also downloads an embedding model and
  # rewires Claude Code's hooks and MCP servers. A bootstrap installs a binary; it
  # does not sign the user up for a background agent.
  if [ "$CLONE_STATE" = "current" ] && [ -x "$bin" ]; then
    skip "witness -> already built"
  else
    spin_start "compiling witness (CGO off, single static binary)"
    if run make -C "$dir" build; then
      spin_stop
      ok "witness -> built"
    else
      spin_stop
      warn "witness -> build failed; skipping the link"
      return 0
    fi
  fi

  # link_once dies when the source is missing, and in a dry run nothing was built,
  # so the link is described rather than attempted.
  #
  # The two reasons the binary can be absent are NOT the same and must not print the
  # same line. In a dry run it is absent because nothing was built, which is expected.
  # In a live run the build reported success and the artifact is not where we looked --
  # upstream renamed the output, or the Makefile cross-compiled -- and that is a
  # failure. Printing "would link ..." for both put a subjunctive line in a live
  # transcript, emitted no warn, and left MACBOOT_WARNED at 0, so the closing box was
  # green for a run that installed no binary at all.
  if [ -f "$bin" ]; then
    link_once "$bin" "$BIN_DIR/witness"
  elif [ "$DRY_RUN" = "1" ]; then
    log "would link $bin -> $BIN_DIR/witness"
  else
    warn "witness -> the build succeeded but $bin does not exist, so nothing was
     linked. Check what 'make -C $dir build' actually produced."
  fi
}

tool_daylogs() {
  dir="$MACBOOT_SRC/daylogs"
  need uv daylogs 30-python.sh || return 0
  clone_or_pull https://github.com/IngTian/daylogs.git daylogs "$dir" || return 0
  have_checkout "$dir" || return 0
  # From the checkout, not from PyPI: the point of this module is that these are
  # built from source you can read and change.
  uv_tool_install "$dir" daylogs
}

tool_manifold() {
  dir="$MACBOOT_SRC/manifold"
  saver="$dir/build/Manifold.saver"
  dest="$MACBOOT_HOME/Library/Screen Savers"
  need swiftc manifold "the Xcode Command Line Tools" || return 0
  clone_or_pull https://github.com/IngTian/manifold.git manifold "$dir" || return 0
  have_checkout "$dir" || return 0
  # Only answerable once the checkout exists; in a dry run there is nothing to
  # inspect and claiming "upstream layout changed" would be a lie.
  if [ -d "$dir" ] && [ ! -f "$dir/scripts/build.sh" ]; then
    warn "manifold -> scripts/build.sh is gone; upstream layout changed, skipping"
    return 0
  fi

  # Its own `build.sh install` writes to $HOME/Library/Screen Savers directly,
  # which ignores MACBOOT_HOME and bypasses run(). So: build only, then place the
  # bundle ourselves.
  if [ "$CLONE_STATE" = "current" ] && [ -d "$saver" ]; then
    skip "manifold -> already built"
  else
    spin_start "compiling Manifold.saver (universal, ~30s)"
    if run bash "$dir/scripts/build.sh"; then
      spin_stop
      ok "manifold -> built"
    else
      spin_stop
      warn "manifold -> build failed; nothing installed"
      return 0
    fi
  fi

  # cmp on the executable, not a timestamp: rsync would happily reinstall an
  # identical bundle every run and the changed counter is the only evidence the
  # double-run test has.
  exe="Contents/MacOS/Manifold"
  if [ -f "$saver/$exe" ] && cmp -s "$saver/$exe" "$dest/Manifold.saver/$exe"; then
    skip "manifold -> the installed .saver is already this build"
    return 0
  fi
  run mkdir -p "$dest"
  # rsync -a --delete, not cp -R: copying into an existing bundle MERGES, so the
  # previous build's second architecture slice or a renamed resource survives
  # inside the new .saver and macOS loads a mixture of the two.
  if run rsync -a --delete "$saver/" "$dest/Manifold.saver/"; then
    ok "manifold -> installed to $dest/Manifold.saver"
  else
    warn "manifold -> could not place the .saver in $dest"
    return 0
  fi

  # The last step is a click and cannot be automated: the selected screensaver
  # lives in a preference the pref daemon caches and rewrites, which is the same
  # trap as the Raycast hotkey in notes/MANUAL-STEPS.md.
  log "manifold: choose it in System Settings > Screen Saver > Other (one click, by hand)"
}

tool_trading_desk() {
  slug='IngTian/trading-desk'
  dir="$MACBOOT_SRC/trading-desk"

  # PRIVATE. Anyone else running this bootstrap must get a one-line skip, never an
  # error and never a credential prompt: an unreadable repo is the expected case
  # for every reader of this repo but one.
  #
  # `gh repo view` first because it uses an existing token and answers in under a
  # second. The git fallback is fenced against the two ways a probe hangs a
  # bootstrap: GIT_TERMINAL_PROMPT=0 kills the username prompt, BatchMode=yes kills
  # the passphrase and host-key prompts, and ConnectTimeout bounds the wait --
  # macOS has no timeout(1) before Homebrew, so the timeout has to come from ssh.
  #
  # UserKnownHostsFile=/dev/null is the important one. With the previous
  # StrictHostKeyChecking=accept-new alone, ssh WROTE github.com's host key into
  # ~/.ssh/known_hosts -- creating ~/.ssh itself on a fresh Mac -- as a side effect of
  # asking a question. That is a mutation of the real $HOME, outside run(), during
  # --dry-run: `make mytools-plan` did it on any machine where gh is absent or the
  # `gh repo view` fails, which is every machine but the author's. Verified by pointing
  # the file at a nonexistent scratch path: ssh created a 92-byte file and announced
  # "Permanently added 'github.com'".
  #
  # Discarding the key is sound HERE and only here: the answer is used solely to choose
  # between two URL spellings, and the clone that follows runs under the user's real ssh
  # config with normal host-key verification. LogLevel=ERROR suppresses the "Permanently
  # added" line, which would otherwise announce a write that no longer happens.
  url=''
  # Neither probe runs in a dry run. The known_hosts leak above was fixed by hardening
  # the ssh probe, but `gh repo view` has its own write: on first use gh creates
  # ~/.local/state/gh/device-id (measured against a fresh HOME) and makes an
  # authenticated API call. A dry run must write nothing anywhere, and since nothing is
  # cloned there the answer is only needed to choose between two URL spellings.
  if [ "$DRY_RUN" = "1" ]; then
    log "would check whether $slug is reachable (gh, then ssh) and clone it into $dir if so"
    return 0
  fi
  if has gh && gh repo view "$slug" >/dev/null 2>&1; then
    url="https://github.com/$slug.git"
  elif GIT_TERMINAL_PROMPT=0 \
    GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR' \
    git ls-remote --exit-code -h "git@github.com:$slug.git" >/dev/null 2>&1; then
    url="git@github.com:$slug.git"
  fi
  if [ -z "$url" ]; then
    skip "trading-desk -> no access to $slug (it is private; this is the expected result unless it is yours)"
    return 0
  fi

  need uv trading-desk 30-python.sh || return 0
  clone_or_pull "$url" trading-desk "$dir" || return 0
  have_checkout "$dir" || return 0
  # The distribution is named `trades`; the command it installs is `desk`.
  uv_tool_install "$dir" trades
}

# ---------------------------------------------------------------------------

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) MACBOOT_MYTOOLS=1 ;;
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

  # Asked per tool, not all-or-nothing.
  #
  # These are four unrelated nice-to-haves with four different toolchains -- Go, uv, Swift,
  # and a private repo most readers cannot see -- so "yes to the set" was the wrong shape:
  # wanting daylogs is not wanting a screensaver. Each answer defaults to NO, and on a
  # non-tty run or under --yes nothing is asked and nothing is built, which is what keeps
  # `curl | bash` and tests/double-run.sh from cloning four repos.
  #
  # --force (and MACBOOT_MYTOOLS=1, which `make mytools` sets) still means yes to all,
  # because the point of that flag is not having to answer.
  if [ "$MACBOOT_MYTOOLS" != "1" ] && [ "$DRY_RUN" != "1" ] &&
    { [ ! -t 0 ] || [ "$MACBOOT_YES" = "1" ]; }; then
    skip "mytools -> nothing asked (no terminal, or --yes). Run: make mytools"
    summary "mytools"
    return 0
  fi

  log "mytools: four optional tools of mine. Checkouts land in $MACBOOT_SRC and are"
  log "kept, never deleted, so you can edit them. Say no to any you do not want."
  [ "$DRY_RUN" != "1" ] ||
    log "(dry run: showing all four, since a live run may be told yes to any of them)"

  # want <tool> -- yes if --force/MACBOOT_MYTOOLS was given, else ask.
  #
  # Always yes in a dry run, and that is the honest answer rather than a shortcut: a plan
  # has to show every mutation a live run could make, and which tools a live run builds is
  # decided by answers a dry run does not have. Answering `n` here would print a plan for
  # nothing and quietly drop four repos' worth of clone-and-build from `make plan`.
  want() { [ "$MACBOOT_MYTOOLS" = "1" ] || [ "$DRY_RUN" = "1" ] || ask "build $1?" n; }

  if want "witness (Go: a local semantic-search index)"; then
    step "witness (Go, public)"
    tool_witness
  fi
  if want "daylogs (Python: a day-log CLI)"; then
    step "daylogs (Python, public)"
    tool_daylogs
  fi
  if want "manifold (Swift: a screensaver)"; then
    step "manifold (Swift screensaver, public)"
    tool_manifold
  fi
  if want "trading-desk (private -- skipped unless you can see the repo)"; then
    step "trading-desk (private)"
    tool_trading_desk
  fi

  summary "mytools"
}

main "$@"
