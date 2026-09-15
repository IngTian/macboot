#!/usr/bin/env bash
# 00-preflight.sh -- inspect the machine before anything mutates it.
#
# This module deliberately calls run() exactly zero times: it only reads. That is
# why a --dry-run transcript and a live transcript are byte-identical here, and it
# is also why every finding has to be a warn or a die -- there is no third option
# like "fix it quietly". The point is to fail on the two conditions that make
# later modules fail *confusingly* (no Xcode CLT, wrong CPU personality) and to
# say out loud the ones the owner has to decide about (MDM, no backup, low disk).
set -euo pipefail
# The path is computed, so plain `shellcheck` cannot follow it and emits SC1091,
# which is an info that still makes the exit status non-zero. `shellcheck -x`
# resolves it via the source= directive; the disable keeps the un-flagged
# invocation clean too. Nothing is hidden: if the file is absent, bash aborts on
# the next line long before shellcheck's opinion matters.
# shellcheck source=lib/common.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

#: Warn below this. 20 GB is roughly Xcode CLT + a full Brewfile + one Docker
#: image; under that, `brew install` starts failing mid-build with a link error
#: that reads like a compiler bug rather than a full disk.
PREFLIGHT_MIN_GB=20

usage() {
  cat <<'EOF'
Usage: 00-preflight.sh [--dry-run]

Reports macOS version, arch, Xcode CLT, free disk, MDM enrollment, backup state
and /bin/bash version. Changes nothing, ever; --dry-run is accepted only so the
module takes the same flags as its siblings.
EOF
}

# ---------------------------------------------------------------------------

report_os() {
  local ver build arch translated
  ver="$(sw_vers -productVersion)"
  build="$(sw_vers -buildVersion)"
  arch="$(uname -m)"
  log "macOS $ver ($build) on $arch"

  # Rosetta FIRST, because a translated shell reports x86_64 on an arm64 Mac and would
  # otherwise be indistinguishable from a genuine Intel machine by the check below -- so it
  # would get the wrong error message, telling someone their Apple Silicon Mac is
  # unsupported. Every tool this bootstrap installs from a translated shell would be
  # x86_64: brew would fetch Intel bottles, cgo would build Intel objects, and none of it
  # is visible until something native refuses to link against it.
  translated="$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)"
  if [ "$translated" = "1" ]; then
    die "this shell is running under Rosetta, so it reports $arch on an arm64 Mac.
     Everything installed from here would be x86_64 -- Intel Homebrew bottles included.
     Uncheck 'Open using Rosetta' in the terminal app's Get Info panel, then re-run."
  fi

  # Apple Silicon only, and now enforced rather than assumed. It was always the real
  # target: brew_prefix() hardcodes /opt/homebrew, shell/conf.d/00-path.zsh exports it as a
  # literal, and no CI job has ever run on anything else (macos-26-arm64). Failing here
  # with a sentence is better than failing at the first missing bottle with a link error --
  # which is what an Intel Mac used to get, several modules in, after Homebrew had already
  # populated a prefix nothing else would look in.
  case "$arch" in
    arm64) ;;
    *) die "macboot targets Apple Silicon only, and this reports $arch.
     Nothing here detects an Intel prefix any more: /opt/homebrew is hardcoded in
     lib/common.sh and in shell/conf.d/00-path.zsh. Supporting Intel again means
     restoring both, not just relaxing this check." ;;
  esac
}

# The GUI installer that `xcode-select --install` launches is a separate process
# with its own progress window; this script cannot wait on it, and polling for it
# means a bootstrap that appears hung for 20 minutes. So: instruct, then die.
# Never claim to have installed it.
report_clt() {
  local path pkg
  path="$(xcode-select -p 2>/dev/null || true)"

  # The receipt survives a macOS major upgrade but the directory does not, which
  # leaves `xcode-select -p` printing a path that is not there. Naive checks pass
  # and the first `brew install` dies on a missing clang.
  if [ -n "$path" ] && [ -d "$path" ]; then
    pkg="$(pkgutil --pkg-info=com.apple.pkg.CLTools_Executables 2>/dev/null |
      awk '/^version:/ {print $2}')"
    ok "Xcode CLT at $path${pkg:+ (version $pkg)}"
    return 0
  fi

  if [ -n "$path" ]; then
    warn "xcode-select points at $path, which does not exist (stale receipt)"
  fi
  log "Install the Command Line Tools, then re-run this script:"
  log "    xcode-select --install"
  die "Xcode Command Line Tools are missing. They ship the compiler, git and
     the SDK headers that Homebrew, cgo and every native gem need. The installer
     is a GUI window this script cannot wait on -- run the command above, let it
     finish, then start macboot again."
}

report_disk() {
  local kb gb
  # df the volume that holds $MACBOOT_HOME, not "/": on APFS "/" is the sealed
  # read-only system snapshot, so reporting it invites the question of why the
  # numbers disagree with Finder. -P keeps the output to one unwrapped line even
  # when the device name is long enough to make plain `df` fold the columns.
  kb="$(df -Pk "$MACBOOT_HOME" 2>/dev/null | awk 'NR==2 {print $4}')"
  case "$kb" in
    '' | *[!0-9]*)
      warn "could not read free space for $MACBOOT_HOME (df gave '${kb}')"
      return 0
      ;;
  esac
  gb=$((kb / 1024 / 1024))
  if [ "$gb" -lt "$PREFLIGHT_MIN_GB" ]; then
    warn "only ${gb} GB free on the volume holding $MACBOOT_HOME (want >= ${PREFLIGHT_MIN_GB} GB).
     Note this figure counts purgeable space, so the real headroom may be lower."
  else
    ok "${gb} GB free on the volume holding $MACBOOT_HOME"
  fi
}

report_mdm() {
  # Not fatal: the spec targets a personally-owned Mac, but the audited machine
  # is DEP-enrolled, so this branch is the live one and has to stay a warning.
  if is_managed; then
    warn "this Mac is MDM-enrolled, so admin rights for the Homebrew installer may
     be withheld entirely. Removing the agent is out of scope: it violates policy
     and Jamf reinstalls it."
  else
    ok "no MDM enrollment detected"
  fi

  # The Homebrew installer needs sudo for /opt/homebrew and refuses to proceed
  # without it. Checking group membership here beats discovering it at the
  # password prompt in 10-brew.sh.
  if id -Gn 2>/dev/null | tr ' ' '\n' | grep -qx admin; then
    ok "$(id -un) is an admin (the Homebrew installer needs sudo)"
  else
    warn "$(id -un) is not in the admin group; the Homebrew installer will fail.
     Everything that writes only under \$HOME will still work."
  fi
}

# Backup state. This warns on EVERY run by design (spec: "00-preflight.sh warns
# on every run when tmutil reports no backup destination") -- the audited machine
# had neither a destination nor a local snapshot. Configure nothing: choosing a
# backup destination is the owner's decision, and a script that silently enrolls a
# disk in Time Machine can erase it.
report_backup() {
  local dest snaps
  # Measured: `tmutil destinationinfo` exits 0 even when it prints
  # "No destinations configured", so the exit status tells us nothing and the
  # text is the only signal.
  dest="$(tmutil destinationinfo 2>&1 || true)"
  snaps="$(tmutil listlocalsnapshots / 2>/dev/null |
    grep -c 'com.apple.TimeMachine' || true)"
  [ -n "$snaps" ] || snaps=0

  case "$dest" in
    *'No destinations configured'*)
      if [ "$snaps" -gt 0 ]; then
        warn "no Time Machine destination; only $snaps local APFS snapshot(s) exist.
     Local snapshots live on the same disk that would fail. This is not a backup."
      else
        # Points at a file that ships, and names the HEADING rather than a step number.
        # This one warning has already pointed at two things the user could not act on:
        # `rescue.sh`, a rename this module never followed, and then a retirement
        # checker later removed from the repo. A number would rot the same way -- the
        # backup step is 9 of 9 today and any insertion above it moves it -- so it is
        # named by its title, which is greppable and survives a reorder.
        warn "NO BACKUP OF ANY KIND: no Time Machine destination, no local APFS
     snapshots. Anything this bootstrap moves or replaces is unrecoverable. See
     \"Set up a backup\" in $MACBOOT_ROOT/notes/MANUAL-STEPS.md -- macboot will not do
     it for you: enrolling a disk in Time Machine can erase it, so that choice is yours."
      fi
      ;;
    *)
      ok "Time Machine destination configured; $snaps local snapshot(s)"
      log "$(printf '%s' "$dest" | sed 's/^/     /')"
      ;;
  esac
}

# /bin/bash is 3.2.57 (2007) on every macOS and cannot be assumed newer, because
# these scripts run before Homebrew. Printing it here means a bash-4-ism surfaces
# next to a version number instead of as `declare: -A: invalid option` sixty
# lines into 20-shell.sh.
report_bash() {
  local ver
  [ -x /bin/bash ] || die "/bin/bash is missing or not executable; this bootstrap
     is written for the system bash and cannot run without it"
  ver="$(/bin/bash --version 2>/dev/null | awk 'NR==1 {print $4}')"
  case "$ver" in
    3.2*) ok "/bin/bash $ver (expected; scripts here are bash-3.2 clean)" ;;
    '') warn "could not parse /bin/bash --version output" ;;
    *) warn "/bin/bash reports $ver, not the expected 3.2.x. Fine for running the
     scripts, but it will not catch bash-4-isms that a fresh Mac would reject." ;;
  esac
  # $BASH_VERSION is the interpreter actually executing this file, which is
  # whatever `#!/usr/bin/env bash` resolved to -- often a brew bash 5 on a
  # developed machine. Not the same question as the line above.
  ok "running under bash ${BASH_VERSION:-unknown} ($(command -v bash))"
}

# ---------------------------------------------------------------------------

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run)
        # Read by summary() in common.sh, not here, so shellcheck without -x
        # cannot see the use and calls the assignment dead. The directive sits
        # inside the branch because SC1124: a directive may not precede a single
        # case item, only a complete command.
        # shellcheck disable=SC2034
        DRY_RUN=1
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
  done

  require_macos
  log "preflight: inspecting the machine, changing nothing"

  # The split into two phases is not cosmetic: anything in the first can stop the
  # run, and nothing in the second ever does. Grouping them together is how a
  # "no backup" warning gets read as a failure and a missing compiler gets read
  # as a warning.
  step "hard requirements"
  report_os
  report_clt
  report_bash

  step "advisories (none of these stop the run)"
  report_disk
  report_mdm
  report_backup

  summary "preflight"
}

main "$@"
