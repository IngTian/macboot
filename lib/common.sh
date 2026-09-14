#!/usr/bin/env bash
# macboot — shared helpers. Source this; do not execute it.
#
# Every module in scripts/ sources this file and routes ALL mutation through run().
# That is the whole idempotency and dry-run story: if a module shells out directly,
# --dry-run silently lies, so the rule is mechanical rather than a convention.
#
# BASH 3.2 ONLY. A fresh macOS ships /bin/bash 3.2 (2007) and this code has to run
# before Homebrew exists, so a newer bash cannot be assumed. That rules out
# associative arrays (declare -A), ${var,,} / ${var^^}, mapfile/readarray, and
# negative array indices. shellcheck is configured for bash because it does not
# meaningfully lint zsh, which is the other reason not to write these in zsh.

# Guard against double-sourcing: modules are individually runnable AND run by
# bootstrap.sh, so this file gets sourced twice in a normal run.
if [ -n "${MACBOOT_COMMON_SOURCED:-}" ]; then
  # `return` fails outside a function/sourced context, so the `|| exit 0` is the
  # path taken when someone executes this file instead of sourcing it. shellcheck
  # cannot see that and calls the exit unreachable.
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi
MACBOOT_COMMON_SOURCED=1

# ---------------------------------------------------------------------------
# Configuration, all overridable from the environment so tests can redirect
# everything away from a real home directory.
# ---------------------------------------------------------------------------

#: 1 = print what would happen and change nothing. Set by --dry-run.
DRY_RUN="${DRY_RUN:-0}"

#: Scratch file where a module reports its counters and its warning text back to
#: bootstrap.sh, which runs modules as CHILD processes and therefore cannot see their
#: MACBOOT_* counters. Without it the closing line said "0 warnings" directly after five
#: warnings had scrolled past. A file rather than a pipe: piping a module's output would
#: cost it the tty and with it the colour. Empty when a module is run on its own, and
#: deliberately NOT under $MACBOOT_HOME -- a dry run must leave that untouched.
MACBOOT_TALLY="${MACBOOT_TALLY:-}"

#: 1 = suppress the colour codes (also auto-off when stderr is not a tty).
NO_COLOR="${NO_COLOR:-0}"

#: Where this checkout lives. Modules use it to find Brewfile, apps.tsv, etc.
MACBOOT_ROOT="${MACBOOT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

#: Target home. Overridable so the double-run test can point at a scratch dir.
MACBOOT_HOME="${MACBOOT_HOME:-$HOME}"

#: Appended to every backup filename. Fixed per run, so one run's backups sort
#: together instead of scattering across seconds.
MACBOOT_STAMP="${MACBOOT_STAMP:-$(date +%Y%m%d-%H%M%S)}"

# Gated on stderr, not stdout, because that is where every coloured write in this repo
# goes: `grep -rn '_C_' lib scripts bootstrap.sh` is all `>&2`. With `[ -t 1 ]` a run
# redirected as `./bootstrap.sh 2>run.log` still saw a terminal on the bare stdout side
# and wrote escape codes into the log, while `./bootstrap.sh >out.txt` stripped the colour
# from a transcript still going to the screen -- exactly backwards in both directions.
# One test here fixes log, ok, skip, warn, step, step_end, die, banner and summary at once.
if [ -t 2 ] && [ "$NO_COLOR" != "1" ]; then
  _C_RESET=$'\033[0m'
  _C_DIM=$'\033[2m'
  _C_RED=$'\033[31m'
  _C_GREEN=$'\033[32m'
  _C_YELLOW=$'\033[33m'
  _C_BLUE=$'\033[34m'
else
  _C_RESET=''
  _C_DIM=''
  _C_RED=''
  _C_GREEN=''
  _C_YELLOW=''
  _C_BLUE=''
fi

# Counters, reported by bootstrap.sh at the end. A run that changed nothing should
# print changed=0, which is the observable form of "idempotent".
MACBOOT_CHANGED=0
MACBOOT_SKIPPED=0
MACBOOT_WARNED=0

# ---------------------------------------------------------------------------
# Output. Everything goes to stderr except the machine-readable bits, so a caller
# can pipe stdout without swallowing the narration.
# ---------------------------------------------------------------------------

# No _tty() helper. It existed for exactly two callers, the progress bar and the spinner,
# and both are gone; the one remaining tty question -- whether to emit colour -- is asked
# once at the top of this file instead of per call.

# Glyphs degrade to ASCII when the locale cannot promise UTF-8, and this genuinely changes
# the bytes written: LC_ALL=C emits `> arrow / ok check / -- dot` where a UTF-8 locale emits
# `▸ ✓ ·`, verified with od -c. Only the three that have readers are here -- '✗' was
# assigned for years with no reader at all, and the two block glyphs died with the bar.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8* | *utf8* | *UTF8*) _G_OK='✓' _G_SKIP='·' _G_ARROW='▸' ;;
  *) _G_OK='ok' _G_SKIP='--' _G_ARROW='>' ;;
esac

log() { printf '%s%s%s %s\n' "$_C_BLUE" "$_G_ARROW" "$_C_RESET" "$*" >&2; }
ok() { printf '  %s%s%s %s\n' "$_C_GREEN" "$_G_OK" "$_C_RESET" "$*" >&2; }
skip() {
  MACBOOT_SKIPPED=$((MACBOOT_SKIPPED + 1))
  printf '  %s%s %s%s\n' "$_C_DIM" "$_G_SKIP" "$*" "$_C_RESET" >&2
}
warn() {
  MACBOOT_WARNED=$((MACBOOT_WARNED + 1))
  printf '  %s!%s %s\n' "$_C_YELLOW" "$_C_RESET" "$*" >&2
  # Kept for the closing replay. Warnings are the only output a user must act on, and in
  # a ten-module run they are hundreds of lines above the last screen. The `return 0` is
  # load-bearing: without it a failed append makes warn() the last command of a `&&`
  # chain under `set -e` and kills the caller.
  [ -n "$MACBOOT_TALLY" ] && printf 'W %s\n' "$*" >>"$MACBOOT_TALLY.warn"
  return 0
}

# ---------------------------------------------------------------------------
# Presentation. None of this changes behaviour, and all of it degrades to plain
# lines when stderr is not a terminal, so the transcript a CI job or a `tee`
# captures stays greppable.
# ---------------------------------------------------------------------------

#: The running module's position in the run, and how many modules are in it. Both come
#: from bootstrap.sh's environment: modules are child processes that re-source this file,
#: so `step` cannot keep a counter of its own.
#:
#: MACBOOT_STEP_N is the MODULE index, NOT a step count, and the distinction is the whole
#: bug this pair has had twice. A module's step count is unknown before it runs, so
#: counting steps against a module total made the numerator and the denominator different
#: units: a full run rendered [1/10] [2/10] [2/10] [3/10] [3/10] [4/10] [5/10] [4/10] ...
#: -- 21 renders for 10 modules, going backwards at 5->4 and reaching [12/10] inside
#: 80-mytools, while 99-apps (which calls step zero times) meant [10/10] never printed at
#: all. An earlier comment here claimed that exact class of bug was already fixed, which
#: made it a false all-clear over live wrong output.
MACBOOT_STEP_TOTAL="${MACBOOT_STEP_TOTAL:-0}"
MACBOOT_STEP_N="${MACBOOT_STEP_N:-0}"
_STEP_STARTED_AT=0
_STEP_LABEL=''

# banner -- the one-time header. Prints the mode, because someone reading a
# scrollback needs to know whether what follows actually happened.
#
# Pure ASCII, and that is the point rather than the joke: the box-drawing header this
# replaces hardcoded U+250C/2500/2502/2514 and so BYPASSED the glyph table above -- the one
# mechanism in this file for not emitting multi-byte glyphs when the locale does not promise
# UTF-8, ignored by the very first thing the tool prints. (An earlier version of this comment
# said it "rendered as mojibake". That was never measured: printf writes the same bytes
# either way and whether they render is the terminal's business. Bypassing the mechanism is
# the defect; what a given terminal then did with it is not knowable from here.)
# ASCII art needs no second code path, so there is nothing here to fall out of sync.
# 51 columns at its widest.
banner() {
  local mode
  mode='live'
  [ "$DRY_RUN" = "1" ] && mode='dry run - nothing will be changed'
  printf '\n%s   ^__^%s          macboot\n' "$_C_BLUE" "$_C_RESET" >&2
  printf '%s   (oo)\\_______%s   %s%s%s\n' "$_C_BLUE" "$_C_RESET" "$_C_DIM" "$mode" "$_C_RESET" >&2
  printf '%s   (__)\\       )\\/\\%s\n' "$_C_BLUE" "$_C_RESET" >&2
  printf '%s       ||----w ||%s\n\n' "$_C_BLUE" "$_C_RESET" >&2
}

# step <label> -- begin a step of the current module. Closes the previous one's timing.
#
# The "[n/total]" prefix is not decoration: tests/dry-run-purity.sh flags any column-0
# line whose first word is a mutating verb, and labels like "nvm v0.40.1" and
# "uv (vendor installer, not Homebrew)" clear that scan only because of the prefix.
# No increment here -- the number is the module's position, which bootstrap.sh owns.
step() {
  [ -n "$_STEP_LABEL" ] && step_end
  _STEP_LABEL="$1"
  _STEP_STARTED_AT=$(date +%s)
  if [ "$MACBOOT_STEP_TOTAL" -gt 0 ]; then
    printf '\n%s[%d/%d]%s %s%s%s\n' "$_C_DIM" "$MACBOOT_STEP_N" "$MACBOOT_STEP_TOTAL" \
      "$_C_RESET" "$_C_BLUE" "$1" "$_C_RESET" >&2
  else
    printf '\n%s%s%s\n' "$_C_BLUE" "$1" "$_C_RESET" >&2
  fi
}

# step_end -- report how long the current step took. Timing is not vanity: it is
# how you find out that one module is responsible for most of a slow bootstrap.
step_end() {
  local elapsed
  [ -n "$_STEP_LABEL" ] || return 0
  elapsed=$(($(date +%s) - _STEP_STARTED_AT))
  [ "$elapsed" -ge 2 ] && printf '  %s%ss%s\n' "$_C_DIM" "$elapsed" "$_C_RESET" >&2
  _STEP_LABEL=''
}

# INT and TERM RE-RAISE the signal. They used to share an EXIT handler whose only job was
# stopping a spinner, and a bash trap handler that simply returns does NOT terminate the
# script.
# So Ctrl-C was swallowed outright: the module resumed at the next command and ran every
# remaining mutation to completion. Measured through a real pty -- ^C at mutation 3 of 12
# left all 12 on disk, and stripping this one line made the same run stop at 3. On a real
# Mac that meant Ctrl-C during 60-macos.sh still applied the remaining `defaults` writes
# and Ctrl-C during 20-shell.sh still finished rewriting .zshrc, after the user had
# decided to stop ("wrong machine", "I meant --dry-run"), with bootstrap.sh printing
# "interrupted" only once the child had already done everything. It also meant mark_done
# was never reached, so a module that fully succeeded re-ran anyway -- the opposite of
# what that message promises. Resetting to the default disposition before re-raising is
# what makes the shell die FROM the signal instead of recursing into this handler.
# No EXIT trap here any more: with the spinner gone there is nothing of common.sh's to
# clean up, so callers own EXIT outright instead of having to chain onto one of ours --
# which four test files each carried a comment about doing correctly.
trap 'trap - INT; kill -INT $$' INT
trap 'trap - TERM; kill -TERM $$' TERM

# die() exits non-zero. Modules should die on "the machine is not in a state I can
# safely change" and warn on "this one optional thing is unavailable" -- a bootstrap
# that aborts the whole run because a nice-to-have cask was renamed is useless.
die() {
  printf '%sFAIL%s %s\n' "$_C_RED" "$_C_RESET" "$*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# The single mutation gate.
# ---------------------------------------------------------------------------

# run <command> [args...]
#
# The ONLY sanctioned way to change the machine. In dry-run it prints and returns 0.
# Two consequences worth knowing before you use it:
#
#   * It is not a shell. `run 'foo | bar'` does not pipe -- it tries to execute a
#     command literally named "foo | bar". For a pipeline or a redirect, use
#     `run bash -c '...'` and accept that dry-run can then only show you the
#     wrapper, not the effect.
#   * It increments the changed counter, which is what makes the double-run test
#     meaningful. Do not bypass it to "just check something" -- reads do not need
#     it, writes always do.
run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '%s would%s %s\n' "$_C_DIM" "$_C_RESET" "$*" >&2
    return 0
  fi
  MACBOOT_CHANGED=$((MACBOOT_CHANGED + 1))
  "$@"
}

# run_quiet <label> <command...> -- run() for a long, NOISY command, with macboot owning
# the terminal instead of the tool.
#
# Forty lines of "==> Fetching / ==> Downloading / ==> Pouring" from four different tools in
# one transcript is noise a reader has to filter by eye. So the output goes to a log, the
# caller prints one line, and the log is shown ONLY when it becomes evidence.
#
# CAPTURED, NOT HIDDEN, and the distinction is the whole design:
#   * on failure the last lines are printed and the log is KEPT and named. brew's own error
#     tells you which build failed and where its logs are, and that is usually the only
#     actionable thing in the run.
#   * `==> Caveats` is always surfaced. It is the one part of brew's output that is
#     instructions rather than progress -- "you must add this to your PATH" belongs on screen.
#   * on success the log is deleted. Nothing accumulates.
#
# stdin comes from /dev/null ON PURPOSE, and it is the load-bearing line. Capturing output
# makes any prompt INVISIBLE, and this repo has been bitten by exactly that twice: a spinner
# painted over the Homebrew installer's sudo prompt (10-brew.sh) and over git's credential
# prompt (80-mytools.sh), and both times the user watched an animation forever with no
# question on screen. With no stdin a command that wants input FAILS immediately and its
# error lands in the log, which is recoverable. An invisible wait is not.
#
# So this must never wrap something that legitimately needs a human: the Homebrew installer
# itself stays unredirected for that reason.
run_quiet() {
  local _rq_label _rq_log _rq_rc
  _rq_label="$1"
  shift
  if [ "$DRY_RUN" = "1" ]; then
    run "$@"
    return 0
  fi
  _rq_log="$(mktemp "${TMPDIR:-/tmp}/macboot-out.XXXXXX")" || _rq_log=/dev/null
  _rq_rc=0
  run "$@" >"$_rq_log" 2>&1 </dev/null || _rq_rc=$?

  if [ "$_rq_rc" != 0 ]; then
    warn "$_rq_label failed (exit $_rq_rc). Last 15 lines, full output kept at $_rq_log:"
    tail -15 "$_rq_log" 2>/dev/null | sed 's/^/     /' >&2
    return "$_rq_rc"
  fi
  if grep -q '^==> Caveats' "$_rq_log" 2>/dev/null; then
    log "caveats from $_rq_label:"
    sed -n '/^==> Caveats/,$p' "$_rq_log" | head -20 | sed 's/^/     /' >&2
  fi
  rm -f "$_rq_log"
  return 0
}

# has <command> -- is it on PATH? Read-only, so it never goes through run().
has() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Asking the human. Both helpers below return WITHOUT asking in every
# non-interactive path, so a caller must still be correct when nobody was asked.
# ---------------------------------------------------------------------------

#: 1 = never stop to ask; take the documented default for every question. Set by --yes.
#: Defaulted here as well as in bootstrap.sh because a module is runnable on its own, and
#: under `set -u` an unset variable in ask() would abort it.
MACBOOT_YES="${MACBOOT_YES:-0}"

# ask <question> [y|n] -- a yes/no question. Default is n.
#
# Silent and answers with the DEFAULT when stdin is not a tty (`curl | bash`, CI,
# tests/double-run.sh), when --yes was passed, or during a dry run -- a dry run changes
# nothing either way and must never block. That is why the defaults are the conservative
# answer everywhere: an unattended run must not acquire things nobody asked for.
ask() {
  local q def reply
  q="$1"
  def="${2:-n}"
  if [ "$DRY_RUN" = "1" ] || [ "$MACBOOT_YES" = "1" ] || [ ! -t 0 ]; then
    case "$def" in y | Y) return 0 ;; *) return 1 ;; esac
  fi
  case "$def" in
    y | Y) printf '  %s?%s %s [Y/n] ' "$_C_BLUE" "$_C_RESET" "$q" >&2 ;;
    *) printf '  %s?%s %s [y/N] ' "$_C_BLUE" "$_C_RESET" "$q" >&2 ;;
  esac
  # `|| reply=''` so a closed stdin mid-run falls back to the default instead of aborting
  # the module under `set -e`.
  read -r reply || reply=''
  [ -n "$reply" ] || reply="$def"
  case "$reply" in y | Y | yes | YES) return 0 ;; *) return 1 ;; esac
}

# pause_for <label> -- stop after printing commands the user has to run themselves.
#
# For the few steps macboot will not do on anyone's behalf. Printing them and carrying on
# is what buries them: by the end of a ten-module run they are hundreds of lines up, which
# is the same reason finish() has to replay warnings at all. Skipped in every
# non-interactive path, so it can never hang a `curl | bash` or a test.
pause_for() {
  local reply
  if [ "$DRY_RUN" = "1" ] || [ "$MACBOOT_YES" = "1" ] || [ ! -t 0 ]; then
    return 0
  fi
  printf '  %s>%s %s -- Enter to continue, Ctrl-C to stop here: ' \
    "$_C_YELLOW" "$_C_RESET" "$1" >&2
  read -r reply || true
}

# ---------------------------------------------------------------------------
# Filesystem helpers
# ---------------------------------------------------------------------------

# link_once <src> <dst>
#
# Symlink src -> dst, idempotently, without ever destroying a real file.
#
# Three cases, and the third is the one naive versions get wrong:
#   1. dst is already our symlink to src  -> nothing, skip.
#   2. dst does not exist                 -> link it.
#   3. dst is a real file or a link elsewhere -> back it up ONCE, then link.
#
# The "once" matters: a version that backs up unconditionally turns every re-run
# into another dst.bak.<stamp>, so ten runs leave ten copies and the real original
# is buried. Because case 1 exits early, our own symlink is never backed up.
link_once() {
  local src dst backup
  src="$1"
  dst="$2"
  [ -n "$src" ] && [ -n "$dst" ] || die "link_once needs <src> <dst>"
  [ -e "$src" ] || die "link_once: source does not exist: $src"

  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    skip "link $dst -> already correct"
    return 0
  fi

  run mkdir -p "$(dirname "$dst")"

  if [ -e "$dst" ] || [ -L "$dst" ]; then
    backup="$dst.bak.$MACBOOT_STAMP"
    warn "link $dst -> existing file moved to $(basename "$backup")"
    run mv "$dst" "$backup"
  fi

  run ln -s "$src" "$dst"
  ok "link $dst -> $src"
}

# ensure_block <file> <marker> <<'EOF' ... EOF
#
# Idempotently maintain a fenced region in a config file, reading the body from
# stdin. A re-run REPLACES the block rather than appending a second copy, which is
# the difference between a profile you can re-bootstrap and one that grows a
# duplicate PATH export every time.
#
# The fence is literal so it survives hand-editing around it:
#   # >>> macboot:<marker> >>>
#   ...body...
#   # <<< macboot:<marker> <<<
#
# Creates the file if absent. Leaves everything outside the fence untouched.
#
# NOTE ON run(): this helper writes with redirects rather than through run(), because
# a redirect is not a command run() can invoke. It is DRY_RUN-guarded on both paths
# below and it increments MACBOOT_CHANGED by hand, so the counters and --dry-run stay
# honest -- but "grep for run() to audit the writes" does not find this function, and
# it is the one that edits ~/.zshrc. link_once and defaults_set are the same shape.
ensure_block() {
  local file marker begin end body desired current tmp mode
  file="$1"
  marker="$2"
  [ -n "$file" ] && [ -n "$marker" ] || die "ensure_block needs <file> <marker>"

  begin="# >>> macboot:$marker >>>"
  end="# <<< macboot:$marker <<<"
  body="$(cat)"
  desired="$begin
$body
$end"

  if [ -f "$file" ] && grep -qF "$begin" "$file"; then
    current="$(awk -v b="$begin" -v e="$end" \
      'index($0,b){f=1} f{print} index($0,e){f=0}' "$file")"
    if [ "$current" = "$desired" ]; then
      skip "block $marker in $(basename "$file") -> already current"
      return 0
    fi
    if [ "$DRY_RUN" = "1" ]; then
      printf '%s would%s replace block %s in %s\n' \
        "$_C_DIM" "$_C_RESET" "$marker" "$file" >&2
      return 0
    fi
    tmp="$file.macboot.$$"
    # Anchored to the FIRST MATCHED PAIR, and it refuses to write at all if the pair
    # does not close.
    #
    # The previous version toggled on both fences with no memory: `index($0,b){f=1;next}
    # index($0,e){f=0;next} !f{print}`. A begin fence with no end fence therefore left it
    # toggled on to end-of-file and DELETED every line below the marker -- the user's own
    # aliases, exports and prompt setup -- while printing a green "block replaced" and
    # taking no backup. Reproduced on a 10-line .zshrc: the 4 lines of personal config
    # below the fence were gone after one run. One hand-edit that drops the closing line
    # is enough, and `index()` is SUBSTRING matching, so a comment merely quoting the
    # fence text re-opened the delete even in a file whose real pair was well formed.
    # `seen` closes both: after one region every remaining line is copied verbatim, and
    # END makes "never closed" an error instead of a silent truncation.
    if ! awk -v b="$begin" -v e="$end" '
      seen { print; next }
      !f && index($0, b) { f = 1; next }
      f && index($0, e) { f = 0; seen = 1; next }
      !f { print }
      END { if (!seen) exit 1 }' "$file" >"$tmp"; then
      rm -f "$tmp"
      warn "block $marker in $(basename "$file"): found the opening fence but no closing
     fence after it, so macboot cannot tell where its own block ends. NOTHING was
     changed -- deleting to end-of-file would take your own config with it. Restore
     the closing line, or delete the opening one:
         $end"
      return 0
    fi
    printf '%s\n' "$desired" >>"$tmp"
    if [ -L "$file" ]; then
      # Write THROUGH the symlink. `mv tmp link` replaces the LINK ITSELF with a
      # regular file: the dotfiles repo it pointed into keeps a stale copy, the live
      # file silently detaches from it, every later edit in that repo stops taking
      # effect, and no backup is taken because link_once is not involved. macboot is
      # a public repo, so a ~/.zshrc symlinked out of a stow/chezmoi checkout is an
      # ordinary case. Atomicity is traded away knowingly; a detached dotfiles repo
      # is the worse failure, because it is silent and discovered weeks later.
      # The recovery file is named on purpose: `rm -f "$tmp"` runs only AFTER the cat
      # succeeds, so any write error or kill in the (measured: ~2.5 ms) window leaves a
      # COMPLETE copy of the intended file at $tmp, including every preserved line from
      # outside the fence. That is the fact that actually justifies trading atomicity
      # away here, and a message that does not mention it turns the best safety property
      # in this function into one nobody finds.
      cat "$tmp" >"$file" ||
        die "ensure_block: cannot write through symlink $file
     (the complete new file is at $tmp -- copy it into place by hand)"
      rm -f "$tmp"
    else
      # Carry the original mode across before the rename: a fresh temp file gets
      # umask defaults, which quietly widens a 0600 config to 0644.
      if mode="$(stat -f '%Lp' "$file" 2>/dev/null)" && [ -n "$mode" ]; then
        chmod "$mode" "$tmp"
      fi
      mv "$tmp" "$file" || die "ensure_block: cannot replace $file (new file left at $tmp)"
    fi
    MACBOOT_CHANGED=$((MACBOOT_CHANGED + 1))
    ok "block $marker in $(basename "$file") -> replaced"
    return 0
  fi

  if [ "$DRY_RUN" = "1" ]; then
    printf '%s would%s append block %s to %s\n' \
      "$_C_DIM" "$_C_RESET" "$marker" "$file" >&2
    return 0
  fi
  run mkdir -p "$(dirname "$file")"
  # Checked, like the two write paths above. Unchecked, a destination that cannot be
  # written -- a symlink into a read-only volume is the realistic one -- printed
  # "line 397: Permission denied" from the shell and then macboot's own green
  # "block appended", incremented MACBOOT_CHANGED and returned 0: a false success that
  # also made the changed counter, and therefore the double-run test, meaningless.
  printf '\n%s\n' "$desired" >>"$file" ||
    die "ensure_block: cannot append the $marker block to $file"
  MACBOOT_CHANGED=$((MACBOOT_CHANGED + 1))
  ok "block $marker in $(basename "$file") -> appended"
}

# ---------------------------------------------------------------------------
# macOS helpers
# ---------------------------------------------------------------------------

# defaults_set <domain> <key> <type> <value>
#
# Write a default only when the current value differs, so a re-run reports skip
# rather than change. `defaults write` is itself idempotent in effect, but calling
# it unconditionally makes the changed counter meaningless -- and that counter is
# how the double-run test proves anything.
defaults_set() {
  local domain key type value current want
  domain="$1"
  key="$2"
  type="$3"
  value="$4"
  current="$(defaults read "$domain" "$key" 2>/dev/null || true)"
  # Booleans read back as 0/1, so normalise before comparing or every run "changes".
  want="$value"
  case "$type" in
    -bool) case "$value" in true | yes | 1) want=1 ;; *) want=0 ;; esac ;;
  esac
  if [ "$current" = "$want" ]; then
    skip "defaults $domain $key -> already $want"
    return 0
  fi
  run defaults write "$domain" "$key" "$type" "$value"
  ok "defaults $domain $key -> $value"
}

# is_managed -- is this Mac enrolled in MDM?
#
# Not fatal: macboot targets a personally-owned Mac, but a managed one should get a
# loud warning rather than a confusing half-run, because Jamf silently reverts some
# defaults and withholds admin for others.
is_managed() {
  profiles status -type enrollment 2>/dev/null | grep -qi 'Enrolled via DEP: Yes\|MDM enrollment: Yes'
}

# brew_prefix -- Homebrew's prefix, without assuming it is installed yet.
#
# Two branches, not four. This repo targets Apple Silicon only (00-preflight.sh refuses
# anything else), where Homebrew's prefix is /opt/homebrew, so the /usr/local branch and
# the `uname -m` fallback that chose between them are gone. `brew --prefix` is still asked
# first rather than assumed: it costs one subprocess and it is the only thing that gets a
# non-default prefix right.
brew_prefix() {
  if has brew; then
    brew --prefix
  else
    echo /opt/homebrew
  fi
}

# require_macos -- refuse to run anywhere else. The scripts write to ~/Library and
# call `defaults`; on Linux they would fail later and less clearly.
require_macos() {
  [ "$(uname -s)" = "Darwin" ] || die "macboot is macOS only (found $(uname -s))"
}

# summary -- the closing line. changed=0 on a second consecutive run is the whole
# idempotency claim, so print it every time rather than only on request.
#
# Warnings are counted and echoed here because a warning 200 lines up scrolls away.
# A bootstrap whose problems are only visible mid-transcript trains people to ignore
# the transcript.
#
# One line, not a three-line box: this is called 15+ times in a full run (every module,
# bootstrap twice, every test), so the boxes were 44 of `make plan`'s 281 lines. The cow
# carries the signal that the box's colour used to -- yellow if anything warned, green if
# anything changed, dim on a clean changed=0 re-run -- and being ASCII it also survives
# LC_ALL=C, which the box's `┌ │ └` did not.
summary() {
  local name tail_note col
  step_end
  name="${1:-macboot}"
  tail_note=''
  # Short, and ASCII: banner() already said "dry run - nothing will be changed", and the
  # em-dash here was the last non-ASCII byte in an entire C-locale transcript.
  [ "$DRY_RUN" = "1" ] && tail_note='  (dry run)'

  if [ "$MACBOOT_WARNED" -gt 0 ]; then
    col="$_C_YELLOW"
  elif [ "$MACBOOT_CHANGED" -gt 0 ]; then
    col="$_C_GREEN"
  else
    col="$_C_DIM"
  fi

  # Report the counters up to whoever ran this module, if anyone is listening.
  [ -n "$MACBOOT_TALLY" ] && printf '%s %s %s\n' \
    "$MACBOOT_CHANGED" "$MACBOOT_SKIPPED" "$MACBOOT_WARNED" >>"$MACBOOT_TALLY"

  printf '\n%s   ^__^ (oo)%s %s%s:%s %s%s%s changed  %s%s%s skipped  %s%s%s warnings%s\n' \
    "$col" "$_C_RESET" "$_C_DIM" "$name" "$_C_RESET" \
    "$_C_GREEN" "$MACBOOT_CHANGED" "$_C_RESET" \
    "$_C_DIM" "$MACBOOT_SKIPPED" "$_C_RESET" \
    "$([ "$MACBOOT_WARNED" -gt 0 ] && printf '%s' "$_C_YELLOW" || printf '%s' "$_C_DIM")" \
    "$MACBOOT_WARNED" "$_C_RESET" "$tail_note" >&2
}
