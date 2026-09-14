#!/usr/bin/env bash
# tests/bootstrap-markers.sh -- exercise bootstrap.sh itself.
#
# Nothing else in the suite runs bootstrap.sh. tests/double-run.sh deliberately invokes
# modules directly (its markers would make the second pass a no-op for the wrong
# reason) and tests/dry-run-purity.sh only reads its transcript, so the state-marker
# logic, --restart, the --only/--skip matcher and the resume path were verified by
# nothing -- which is where the "a targeted run permanently suppresses a module from
# `make all`" bug lived.
#
# The modules are FAKES in a scratch MACBOOT_ROOT: five lines each, no installers, no
# network, no sudo. That is the point. Testing bootstrap's control flow against real
# modules would mean running Homebrew to find out whether a marker file was written.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

MACBOOT_TEST_TMP="${MACBOOT_TEST_TMP:-${TMPDIR:-/tmp}}"
DRY_RUN=0 # this test's own bookkeeping is never a dry run

REAL_ROOT="$MACBOOT_ROOT"
BOOTSTRAP="$REAL_ROOT/bootstrap.sh"

FAIL_N=0
_fail() {
  FAIL_N=$((FAIL_N + 1))
  warn "$*"
}
# want <label> <expected> <actual>
want() {
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    _fail "$1: expected [$2], got [$3]"
  fi
}

SCRATCH="$(mktemp -d "$MACBOOT_TEST_TMP/macboot-markers.XXXXXX")"
FAKE_ROOT="$SCRATCH/root"
FAKE_HOME="$SCRATCH/home"
STATE="$FAKE_HOME/.macboot/state"
_cleanup() {
  spin_stop
  [ "$FAIL_N" -gt 0 ] || rm -rf "$SCRATCH"
}
trap _cleanup EXIT

mkdir -p "$FAKE_ROOT/scripts" "$FAKE_HOME"
# The fakes source common.sh through their own ../lib, exactly as the real modules do.
ln -s "$REAL_ROOT/lib" "$FAKE_ROOT/lib"

# make_module <name> <exit-code>
make_module() {
  cat >"$FAKE_ROOT/scripts/$1.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "\$(dirname "\${BASH_SOURCE[0]}")/../lib/common.sh"
step "$1: only phase"
printf 'RAN $1\n'
summary "$1"
exit $2
EOF
}
make_module 10-alpha 0
make_module 20-beta 0
make_module 99-omega 0

# boot <args...> -- run bootstrap against the fakes. Prints stdout+stderr, sets _RC.
boot() {
  _RC=0
  MACBOOT_ROOT="$FAKE_ROOT" MACBOOT_HOME="$FAKE_HOME" NO_COLOR=1 MACBOOT_YES=1 \
    bash "$BOOTSTRAP" "$@" >"$SCRATCH/out.txt" 2>&1 || _RC=$?
  cat "$SCRATCH/out.txt"
}
markers() {
  # shellcheck disable=SC2012  # names only, no metadata; ls is fine and portable here
  ls "$STATE" 2>/dev/null | sed 's/\.done$//' | tr '\n' ' ' | sed 's/ $//'
}
ran() { grep -c "^RAN $1\$" "$SCRATCH/out.txt" || true; }

# ---------------------------------------------------------------------------

step "a dry run writes no markers"
boot --dry-run >/dev/null
want "no state dir after --dry-run" "no" "$([ -d "$STATE" ] && echo yes || echo no)"
want "--dry-run exits 0" "0" "$_RC"

step "a full run marks every module, and a second run runs nothing"
boot >/dev/null
want "all three marked" "10-alpha 20-beta 99-omega" "$(markers)"
want "alpha ran once" "1" "$(ran 10-alpha)"
boot >/dev/null
want "second run re-runs nothing" "0" "$(ran 10-alpha)"
want "second run still exits 0" "0" "$_RC"

step "--restart clears the markers and runs everything again"
boot --restart >/dev/null
want "alpha ran again" "1" "$(ran 10-alpha)"
want "all three still marked" "10-alpha 20-beta 99-omega" "$(markers)"

step "a TARGETED run must not mark the module complete"
# The regression this file exists for. `make check` is --only 05 and `make apps` is
# --only 99; when those wrote full markers, every later `make all` skipped the
# unpushed-work gate and never printed the GUI-app list, and only --restart recovered.
rm -rf "$FAKE_HOME/.macboot"
boot --only 20 >/dev/null
want "beta ran" "1" "$(ran 20-beta)"
want "beta was NOT marked" "" "$(markers)"
boot >/dev/null
want "a later full run still runs beta" "1" "$(ran 20-beta)"

step "--only overrides an existing marker"
boot --only 20 >/dev/null
want "beta re-runs despite being marked" "1" "$(ran 20-beta)"

step "a failing module stops the run, names itself, and is not marked"
make_module 20-beta 3
rm -rf "$FAKE_HOME/.macboot"
boot >/dev/null || true
want "exit is non-zero" "1" "$([ "$_RC" != 0 ] && echo 1 || echo 0)"
want "the failure names the module" "1" "$(grep -c '20-beta exited 3' "$SCRATCH/out.txt" || true)"
want "only alpha is marked" "10-alpha" "$(markers)"
want "omega never ran" "0" "$(ran 99-omega)"

step "--keep-going continues past the failure but still exits non-zero"
rm -rf "$FAKE_HOME/.macboot"
boot --keep-going >/dev/null || true
want "omega ran anyway" "1" "$(ran 99-omega)"
want "exit is still non-zero" "1" "$([ "$_RC" != 0 ] && echo 1 || echo 0)"
want "the failed module is not marked" "10-alpha 99-omega" "$(markers)"
make_module 20-beta 0

step "--skip and --only arguments are not glob-expanded"
# Run from a directory containing files named like modules, which is what made
# `--skip 'g*'` expand to a directory listing and silently skip a module nobody named.
mkdir -p "$SCRATCH/cwd/alpha" "$SCRATCH/cwd/beta"
(
  cd "$SCRATCH/cwd" || exit 1
  MACBOOT_ROOT="$FAKE_ROOT" MACBOOT_HOME="$FAKE_HOME" NO_COLOR=1 MACBOOT_YES=1 \
    bash "$BOOTSTRAP" --dry-run --skip '*' >"$SCRATCH/out.txt" 2>&1 || true
)
want "a literal '*' is reported as unmatched, not expanded" \
  "1" "$(grep -c "no module matches '\*'" "$SCRATCH/out.txt" || true)"

step "step numbering is continuous across modules"
rm -rf "$FAKE_HOME/.macboot"
boot --restart >/dev/null
# Three modules, one step each -> [1/3] [2/3] [3/3], never [1/3] three times.
want "steps are numbered 1..3" "1 2 3" \
  "$(grep -oE '\[[0-9]+/3\]' "$SCRATCH/out.txt" | tr -d '[]' | cut -d/ -f1 | tr '\n' ' ' | sed 's/ $//')"

step "an unwritable state dir explains itself instead of dying bare"
rm -rf "$FAKE_HOME/.macboot"
mkdir -p "$STATE"
# The STATE dir itself, not its parent: r-x on .macboot still permits writing into an
# already-traversable state/, so chmod-ing the parent proves nothing. The realistic
# cause of this state is one `sudo ./bootstrap.sh` leaving root-owned bookkeeping.
chmod 500 "$STATE"
boot >/dev/null || true
chmod 700 "$STATE"
# The module succeeded; only the bookkeeping failed, so the run must finish and warn.
want "the run still completed" "1" "$(ran 99-omega)"
# One warning per module, so assert "at least one" rather than an exact count -- the
# count is the number of modules, which is a fact about this fixture, not about the
# behaviour under test.
want "the marker failure is explained, not a bare permission error" "yes" \
  "$([ "$(grep -c 'will run again on the next' "$SCRATCH/out.txt" || true)" -gt 0 ] &&
    echo yes || echo no)"
want "the run did not die on it" "0" "$_RC"

# ---------------------------------------------------------------------------

summary "bootstrap-markers"
if [ "$FAIL_N" -gt 0 ]; then
  die "$FAIL_N assertion(s) failed; evidence kept in $SCRATCH"
fi
