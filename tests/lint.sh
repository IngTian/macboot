#!/usr/bin/env bash
# tests/lint.sh -- shellcheck (-s bash) and shfmt (-i 2 -ci -d) over every shell
# file in the checkout. Exits non-zero on any finding, so CI can gate on it.
#
# Two deliberate choices:
#   * Files are DISCOVERED by walking the tree, never listed. A hardcoded list is
#     the thing scripts/45-foo.sh gets forgotten from, and the one unlinted module
#     is where the bash-4-ism that a fresh macOS 3.2 rejects survives to release.
#   * Findings are buffered and printed after the progress bar rather than as they
#     appear. A redrawn bar interleaved with a shellcheck report shreds both, and
#     an unreadable lint report gets ignored.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

#: Overridable so CI can pin a build. Absent before Homebrew exists, which is why
#: this is a test and not part of the bootstrap.
SHELLCHECK="${SHELLCHECK:-shellcheck}"
SHFMT="${SHFMT:-shfmt}"

# This test only reads and only writes its own mktemp scratch, so nothing here
# goes through run(). Inheriting DRY_RUN=1 must not turn it into a no-op that
# still prints a green summary -- a lint gate that passes without running is
# worse than no gate, so the flag is pinned off for our own bookkeeping.
DRY_RUN=0

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/macboot-lint.XXXXXX")"
# Chained, not replaced: common.sh installs `trap spin_stop EXIT` and dropping it
# here would leave a spinner alive on any early exit.
trap 'spin_stop; rm -rf "$TMPD"' EXIT

# Pruned paths: .git, and the scratch trees the other two tests may leave behind
# (tmp/, fakehome/, .macboot/ are all in .gitignore for exactly that reason).
# Linting a copy of the tree reports every finding twice, against a path that is
# about to be deleted. *.bak.* is link_once's backup of whatever the machine had
# before macboot ran -- someone else's file, often not even valid bash.
discover() {
  find "$MACBOOT_ROOT" \
    \( -name .git -o -name .macboot -o -name fakehome -o -name tmp -o -name node_modules \) \
    -prune -o -type f -name '*.sh' ! -name '*.bak.*' -print |
    LC_ALL=C sort
}

FILES=()
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  FILES+=("$_f")
done < <(discover)

# Under `set -u` bash 3.2 aborts on "${FILES[@]}" when the array is empty, so the
# count is checked before anything expands it. An empty result also means the
# discovery glob broke, which must fail loudly rather than report "0 findings".
[ "${#FILES[@]}" -gt 0 ] ||
  die "no *.sh files found under $MACBOOT_ROOT (broken checkout, or discover() over-pruned)"

has "$SHELLCHECK" || die "$SHELLCHECK not found. brew install shellcheck (it is in the
     must-have Brewfile tier precisely because this repo is shell)"
has "$SHFMT" || die "$SHFMT not found. brew install shfmt"

TOTAL="${#FILES[@]}"
FAILED=0

# check <tool-label> <report-file> <command...> -- run one tool over every file,
# one file at a time so a finding names the file that owns it, and so progress is
# a real fraction rather than a spinner over an opaque batch.
#
# Every local is _-prefixed on purpose: the helpers in common.sh are written for
# bash 3.2 without `local`, so progress() assigns to the global `label`, `i`,
# `bar`, `cur` and `tot`. A plain `label=` here is silently overwritten by the
# first progress() call, and the report then names the wrong tool.
check() {
  _lbl="$1"
  _report="$2"
  shift 2
  : >"$_report"
  for _file in "${FILES[@]}"; do
    _rel="${_file#"$MACBOOT_ROOT"/}"
    # `|| true` instead of letting set -e fire: a finding is data this test
    # collects, not an error that should abort the sweep at the first file.
    _out="$("$@" "$_file" 2>&1 || true)"
    if [ -n "$_out" ]; then
      FAILED=$((FAILED + 1))
      printf '%s -- %s\n%s\n\n' "$_lbl" "$_rel" "$_out" >>"$_report"
      warn "$_lbl: $_rel"
    fi
  done
}

step "shellcheck ($TOTAL files)"
# -s bash: these files are #!/usr/bin/env bash and shellcheck does not
# meaningfully lint zsh, which is the other reason the modules are not zsh.
# -x -P: every module sources ../lib/common.sh through a $(dirname ...) expansion
# that the linter cannot resolve on its own. Without following the source it
# reports SC1091 on every single file, which drowns the real findings, and it
# cannot see that log/run/die are defined at all.
# (This comment avoids starting a line with the tool's own name: a comment whose
# first word is that name is read as a directive and fails with SC1072.)
check shellcheck "$TMPD/shellcheck.txt" "$SHELLCHECK" -s bash -x -P "$MACBOOT_ROOT"

step "shfmt -i 2 -ci -d ($TOTAL files)"
# -d, not -w: a test must report, never edit. `make lint` is the place a human
# opts into -w. -i 2 -ci match what the rest of the repo is already formatted to.
check shfmt "$TMPD/shfmt.txt" "$SHFMT" -i 2 -ci -d

if [ "$FAILED" -gt 0 ]; then
  printf '\n' >&2
  cat "$TMPD/shellcheck.txt" "$TMPD/shfmt.txt" >&2
fi

[ "$FAILED" -gt 0 ] || ok "$TOTAL files clean under shellcheck and shfmt"

summary "lint"
# summary first, then die: the counters are the point of the run, and a failure
# that exits before printing them makes the report harder to read, not clearer.
[ "$FAILED" -eq 0 ] || die "$FAILED file/tool pair(s) with findings.
     shfmt diffs are fixable with: shfmt -i 2 -ci -w <file>"
