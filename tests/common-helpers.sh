#!/usr/bin/env bash
# tests/common-helpers.sh -- the two helpers in lib/common.sh that can destroy work.
#
# ensure_block is the function that edits ~/.zshrc, and the signal trap is what decides
# whether Ctrl-C stops a module. Both had a defect that a green transcript hid, and
# neither was covered by any test: dry-run-purity asserts on the filesystem AFTER a dry
# run, double-run asserts idempotency, and neither ever hands ensure_block a file a human
# has edited. So these cases are about MALFORMED and INTERRUPTED input, not the happy
# path -- the happy path is already proven by tests/double-run.sh.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

MACBOOT_TEST_TMP="${MACBOOT_TEST_TMP:-${TMPDIR:-/tmp}}"
DRY_RUN=0

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

SCRATCH="$(mktemp -d "$MACBOOT_TEST_TMP/macboot-helpers.XXXXXX")"
_cleanup() {
  [ "$FAIL_N" -gt 0 ] || rm -rf "$SCRATCH"
}
trap _cleanup EXIT

# mkrc <path> -- a .zshrc shaped like a real one: a macboot block with the user's own
# config BELOW it, which is the content every case here is about not losing.
mkrc() {
  cat >"$1" <<'EOF'
export PATH="$HOME/bin:$PATH"
# >>> macboot:shell >>>
OLD BODY
# <<< macboot:shell <<<

# --- my own stuff ---
alias deploy="./scripts/deploy.sh prod"
export AWS_PROFILE=work
EOF
}
mine() { grep -c 'AWS_PROFILE\|deploy' "$1" | tr -d ' '; }

# ---------------------------------------------------------------------------

step "DATA LOSS: a missing closing fence must not delete the rest of the file"
# The awk that removes the old block toggled on each fence with no memory, so an opening
# fence with no closing fence stayed toggled on to EOF and took every line below it --
# with a green "block replaced" line and no backup. One hand-edit is enough to cause it.
F="$SCRATCH/nofence"
mkrc "$F"
sed -i '' '/<<< macboot:shell <<</d' "$F"
BEFORE="$(cat "$F")"
printf 'NEW BODY\n' | ensure_block "$F" shell >/dev/null 2>&1 || true
want "the file is byte-identical (nothing was changed)" "yes" \
  "$([ "$BEFORE" = "$(cat "$F")" ] && echo yes || echo no)"
want "the user's own lines are still there" "2" "$(mine "$F")"

step "DATA LOSS: fence TEXT quoted below a well-formed block must not re-open the delete"
# index() is substring matching, so a line that merely CONTAINS the fence string used to
# toggle the delete back on and eat everything after it.
F="$SCRATCH/quoted"
mkrc "$F"
printf '# see the "# <<< macboot:shell <<<" fence above\nexport KEEPME=1\n' >>"$F"
printf 'NEW BODY\n' | ensure_block "$F" shell >/dev/null 2>&1 || true
# The quoted line ITSELF is the assertion that matters: the old awk matched it with
# index(), treated it as a real closing fence, and deleted it -- silently editing a line
# the user wrote, outside any macboot block.
want "the line that merely quotes the fence is still there" "1" \
  "$(grep -c 'see the' "$F" | tr -d ' ')"
want "the line after the quoted fence survives" "1" "$(grep -c 'KEEPME=1' "$F" | tr -d ' ')"
want "the user's own lines survive" "2" "$(mine "$F")"
want "exactly one opening fence (no duplicate block)" "1" \
  "$(grep -cF '# >>> macboot:shell >>>' "$F" | tr -d ' ')"

step "the ordinary replace still works and is still idempotent"
F="$SCRATCH/ok"
mkrc "$F"
printf 'NEW BODY\n' | ensure_block "$F" shell >/dev/null 2>&1
_before="$MACBOOT_CHANGED"
printf 'NEW BODY\n' | ensure_block "$F" shell >/dev/null 2>&1
want "a second identical call changes nothing" "0" "$((MACBOOT_CHANGED - _before))"
want "the body was replaced" "1" "$(grep -c '^NEW BODY$' "$F" | tr -d ' ')"
want "the user's own lines survive" "2" "$(mine "$F")"

step "a write that cannot happen must not report success"
# Unchecked, the append path printed "Permission denied" from the shell and then
# macboot's own green "block appended", and incremented the changed counter -- which is
# the counter tests/double-run.sh reasons about.
mkdir -p "$SCRATCH/ro"
printf 'placeholder\n' >"$SCRATCH/ro/target"
chmod 444 "$SCRATCH/ro/target"
_rc=0
printf 'BODY\n' | ensure_block "$SCRATCH/ro/target" newmark >/dev/null 2>&1 || _rc=$?
want "ensure_block exits non-zero" "yes" "$([ "$_rc" != 0 ] && echo yes || echo no)"
chmod 644 "$SCRATCH/ro/target"

step "INTERRUPT: a signal must stop a module, not let it finish its mutation loop"
# The INT/TERM handler shared the EXIT handler, and a bash trap handler that returns does
# NOT terminate the script: the module resumed at the next command and ran every
# remaining mutation. Ctrl-C during 20-shell.sh therefore still finished rewriting
# .zshrc. SIGTERM is sent directly rather than driving a pty, so the test is
# deterministic; it exercises the same handler.
OUT="$SCRATCH/sig"
mkdir -p "$OUT"
cat >"$SCRATCH/slowmod.sh" <<EOF
set -euo pipefail
. "$MACBOOT_ROOT/lib/common.sh"
i=0
while [ "\$i" -lt 20 ]; do
  i=\$((i + 1))
  : >"$OUT/mutation-\$i"
  sleep 0.2
done
EOF
bash "$SCRATCH/slowmod.sh" &
_pid=$!
# Wait for the loop to be demonstrably running, then signal it.
_w=0
while [ ! -f "$OUT/mutation-2" ] && [ "$_w" -lt 50 ]; do
  sleep 0.1
  _w=$((_w + 1))
done
kill -TERM "$_pid" 2>/dev/null || true
wait "$_pid" 2>/dev/null || true
sleep 0.5
_done="$(find "$OUT" -name 'mutation-*' | wc -l | tr -d ' ')"
want "it stopped early instead of completing all 20" "yes" \
  "$([ "$_done" -lt 20 ] && echo yes || echo no)"

# ---------------------------------------------------------------------------

summary "common helpers"
if [ "$FAIL_N" -gt 0 ]; then
  die "$FAIL_N assertion(s) failed; evidence kept in $SCRATCH"
fi
