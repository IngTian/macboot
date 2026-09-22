#!/usr/bin/env bash
# 20-shell.sh -- install the shipped zsh config WITHOUT owning the user's ~/.zshrc.
#
# The whole module is four moves:
#   1. report the login shell, and print the chsh command instead of running it;
#   2. syntax-check every shipped zsh file BEFORE anything links to it;
#   3. symlink shell/rc.zsh into ~/.config/macboot/, and create the user's own
#      drop-in directory next to it;
#   4. ensure_block a single `source` line into the real .zshrc.
#
# Only ONE line is ever added to .zshrc, and it never has to grow: everything macboot
# configures lives in numbered units under shell/conf.d/, and anything the user adds
# lives in ~/.config/zsh/conf.d/. That is the answer to a 242-line rc file in which
# ~/.local/bin was prepended twice and conda base twice, because nvm, conda, gcloud,
# oh-my-zsh, p10k, bun and opencode had each appended their own block and nothing ever
# removed one.
#
# .zshrc is never replaced or truncated. This repo is public: on a stranger's machine
# that file holds work no bootstrap can see, and "I backed it up" is a poor answer to
# "my prompt, my nvm and my work aliases are gone". Everything macboot owns lives
# between two markers, so a re-run replaces its own block and nothing else, and
# deleting the block is the complete uninstall.
#
# Deliberately out of scope: powerlevel10k. The author's .p10k.zsh is ~90 KB of
# answers to an interactive wizard and cannot be regenerated to the same state, so
# prompt configuration is left to the user, outside the fence or in their own unit.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

#: Where shell/rc.zsh gets linked. The fence in .zshrc points at this path, so the
#: checkout can move without editing .zshrc -- re-running macboot repoints the link.
SHELL_CFG_DIR="$MACBOOT_HOME/.config/macboot"

#: The user's own drop-in directory. macboot creates it and drops a README, and never
#: writes a *.zsh unit into it -- so nothing macboot does can clobber your config.
USER_CONF_DIR="$MACBOOT_HOME/.config/zsh/conf.d"

usage() {
  cat <<'EOF'
Usage: 20-shell.sh [--dry-run]

Links shell/rc.zsh into ~/.config/macboot/, creates ~/.config/zsh/conf.d/ for your
own drop-ins, and adds one fenced source line to your .zshrc. Never rewrites .zshrc
outside its own markers, and never changes the login shell (that needs a password).

EOF
}

# ---------------------------------------------------------------------------
# Where does zsh actually read its rc file from?
# ---------------------------------------------------------------------------

# zdot_dir -- the directory whose .zshrc a new zsh will really read.
#
# NOT simply $MACBOOT_HOME. A user who sets ZDOTDIR=$HOME/.config/zsh in ~/.zshenv
# (the standard way to keep $HOME free of dotfiles) has zsh read
# $ZDOTDIR/.zshrc, so appending the fence to ~/.zshrc writes it into a file no shell
# ever sources -- and the module then reports changed=1 and a green summary while
# installing nothing that loads.
#
# Asked of zsh rather than guessed, because ~/.zshenv is read by EVERY zsh invocation
# and is therefore the one place ZDOTDIR is reliably set; this bash process never ran
# .zshenv and cannot see it. `zsh -c` (no -f) reads it exactly as a real shell would.
zdot_dir() {
  local d
  # A redirected MACBOOT_HOME means a test scratch home: honour it verbatim rather
  # than asking the real zsh, whose answer would point back at the real home.
  if [ "$MACBOOT_HOME" != "${HOME:-}" ]; then
    printf '%s\n' "$MACBOOT_HOME"
    return 0
  fi
  if has zsh &&
    d="$(zsh -c 'print -r -- ${ZDOTDIR:-$HOME}' 2>/dev/null)" &&
    [ -n "$d" ]; then
    printf '%s\n' "$d"
    return 0
  fi
  printf '%s\n' "$MACBOOT_HOME"
}

# ---------------------------------------------------------------------------
# Login shell
# ---------------------------------------------------------------------------

# account_shell -- the login shell recorded for this account.
#
# Read from the account record, not from $SHELL. Terminal emulators, IDE terminals and
# some launchers export SHELL independently of the passwd entry, so `SHELL=/bin/zsh`
# in an account whose real shell is bash makes the naive check answer "already zsh",
# suppress the chsh hint, and leave the whole module inert at login with no warning.
# Silence is the dangerous direction of that error.
account_shell() {
  local s=''
  if has dscl; then
    s="$(dscl . -read "/Users/$(id -un)" UserShell 2>/dev/null |
      sed -n 's/^UserShell: *//p')"
  fi
  # A machine without dscl falls through: getent, then $SHELL, then give up.
  if [ -z "$s" ] && has getent; then
    s="$(getent passwd "$(id -un)" 2>/dev/null | awk -F: '{print $7}')"
  fi
  [ -n "$s" ] || s="${SHELL:-}"
  printf '%s\n' "$s"
}

# chsh is not run, on purpose. It prompts for the account password on the controlling
# tty, so inside `bootstrap.sh | tee log` it either hangs forever or eats the next line
# of input as a password attempt. Printing the exact command costs the user one paste
# and cannot hang the run.
report_login_shell() {
  local cur zsh_path
  cur="$(account_shell)"

  case "$cur" in
    */zsh)
      ok "login shell is $cur (zsh)"
      # A mismatch between the record and $SHELL is worth one line: it explains why a
      # terminal may still be running something else right now.
      case "${SHELL:-}" in
        "$cur" | */zsh) ;;
        '') ;;
        *) log "note: \$SHELL is ${SHELL} in this process, but the account record says $cur" ;;
      esac
      return 0
      ;;
  esac

  # Prefer a zsh that /etc/shells ALREADY lists, because that is the only kind chsh
  # accepts without first editing a root-owned file. A brew zsh is not listed, which is
  # the failure people actually hit.
  zsh_path="$(grep -m1 '/zsh$' /etc/shells 2>/dev/null || true)"
  [ -n "$zsh_path" ] || zsh_path="$(command -v zsh || true)"
  [ -n "$zsh_path" ] || zsh_path=/bin/zsh

  warn "login shell is ${cur:-unknown}, not zsh. Everything this module installs is
     read from .zshrc, so it stays inert until you switch. Run this yourself --
     chsh asks for your password and would hang a scripted run:"
  log "    chsh -s $zsh_path"
  # Worth stopping for: without it every other thing this module just did has no effect
  # at all, and the warning is otherwise eight modules from the end of the run.
  pause_for "switch your login shell with the command above"
}

# ---------------------------------------------------------------------------
# Syntax
# ---------------------------------------------------------------------------

# A syntax error in a sourced rc file breaks EVERY terminal window opened afterwards,
# including the one you would use to fix it, so parse every shipped file before
# anything links to it. `zsh -n` only parses -- it executes nothing.
check_syntax() {
  local f n=0
  if ! has zsh; then
    warn "no zsh on PATH, so the shipped rc files could not be syntax-checked"
    return 0
  fi
  [ -f "$MACBOOT_ROOT/shell/rc.zsh" ] ||
    die "missing shipped file: $MACBOOT_ROOT/shell/rc.zsh (incomplete checkout?)"

  for f in "$MACBOOT_ROOT/shell/rc.zsh" "$MACBOOT_ROOT"/shell/conf.d/*.zsh; do
    [ -f "$f" ] || continue
    zsh -n "$f" 2>/dev/null ||
      die "$(basename "$f") does not parse under $(zsh --version).
     Refusing to link it: a broken rc file makes every new shell unusable.
     Reproduce with: zsh -n $f"
    n=$((n + 1))
  done
  [ "$n" -gt 1 ] || die "found no conf.d units next to rc.zsh (incomplete checkout?)"
  ok "rc.zsh and $((n - 1)) conf.d unit(s) parse"
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

# Only rc.zsh is linked. It locates its units with ${0:A:h}/conf.d, and :A resolves
# THIS symlink, so conf.d is always read from the same checkout as the loader -- no
# second link to keep in step, and `git pull` updates every unit at once.
link_configs() {
  link_once "$MACBOOT_ROOT/shell/rc.zsh" "$SHELL_CFG_DIR/rc.zsh"
}

# The user's drop-in directory, created empty. The README is written once and never
# overwritten: this directory belongs to the user, and a bootstrap that rewrites files
# under it would eventually eat something they meant to keep.
make_user_conf_dir() {
  local readme="$USER_CONF_DIR/README.md"
  if [ -d "$USER_CONF_DIR" ]; then
    skip "drop-in dir $USER_CONF_DIR -> exists"
  else
    run mkdir -p "$USER_CONF_DIR"
    ok "drop-in dir $USER_CONF_DIR -> created"
  fi

  if [ -e "$readme" ]; then
    skip "$(basename "$readme") -> exists, left alone"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    printf '%s would%s write %s\n' "$_C_DIM" "$_C_RESET" "$readme" >&2
    return 0
  fi
  # Not a *.zsh, so the loader's glob never sources it.
  cat >"$readme" <<'EOF'
# Your zsh drop-ins

Every `*.zsh` file here is sourced by macboot's loader, in filename order, merged
with macboot's own units. A new tool means a NEW FILE here -- never another line
appended to `.zshrc`.

    below 50   may add to $fpath        (completions are not loaded yet)
    50         compinit runs, once      (macboot's 50-compinit.zsh)
    above 50   may rely on completions and on the final keymap

A vendor completion snippet belongs ABOVE 50, and getting this wrong is slow rather
than broken. Many of them end with "if compdef is not defined, run compinit" -- so
below 50 they run a SECOND full compinit of their own. Measured: gcloud's
completion.zsh.inc cost 297 ms at 20-gcloud.zsh and almost nothing at 60-gcloud.zsh.
If a unit of yours is unexpectedly slow, `MACBOOT_ZSH_PROFILE=1 exec zsh` names it.

Use two digits: the sort is lexical, so `9-foo.zsh` runs after `80-plugins.zsh`.

A file whose name matches one of macboot's WINS, because yours is loaded second:
write `70-aliases.zsh` here to replace macboot's aliases, or leave it empty to
disable them. You never have to edit anything inside the macboot checkout.

    MACBOOT_ZSH_PROFILE=1 exec zsh    # per-unit startup cost
EOF
  MACBOOT_CHANGED=$((MACBOOT_CHANGED + 1))
  ok "$(basename "$readme") -> written"
}

# The brew-provided files 80-plugins.zsh sources. Missing ones are a warn, never a
# die: an absent zsh-autosuggestions costs you inline suggestions, and aborting the
# bootstrap over that would be worse than the missing feature. Every one is guarded at
# source time in the units too, so a missing file is inert, not broken.
check_support_files() {
  local prefix label formula p entry
  local missing_labels='' missing_formulae=''
  prefix="$(brew_prefix)"

  if [ ! -x "$prefix/bin/brew" ]; then
    warn "Homebrew is not installed at $prefix yet, so zsh-autosuggestions,
     zsh-completions, fzf and autojump cannot be checked. Run 10-brew.sh first;
     the units skip whatever is absent, so nothing here breaks meanwhile."
    return 0
  fi

  # "label:formula:path" triples, not pairs. The label is prose for the human and the
  # formula is what brew understands, and they are NOT the same string: the previous
  # version pasted the label straight into the fix-it line and told the user to run
  # `brew install ... fzf key-bindings ...`, which aborts on an unknown formula named
  # `key-bindings`. The one "copy this to fix it" string was wrong in exactly the case
  # that produced it.
  #
  # Parallel strings instead of an associative array: bash 3.2 has no declare -A, and
  # this file has to run on a fresh macOS before brew's bash exists.
  set -- \
    "zsh-autosuggestions:zsh-autosuggestions:$prefix/share/zsh-autosuggestions/zsh-autosuggestions.zsh" \
    "zsh-completions:zsh-completions:$prefix/share/zsh-completions" \
    "fzf key-bindings:fzf:$prefix/opt/fzf/shell/key-bindings.zsh" \
    "autojump:autojump:$prefix/etc/profile.d/autojump.sh"

  for entry in "$@"; do
    label="${entry%%:*}"
    formula="${entry#*:}"
    formula="${formula%%:*}"
    p="${entry##*:}"
    if [ ! -e "$p" ]; then
      missing_labels="$missing_labels $label"
      missing_formulae="$missing_formulae $formula"
    fi
  done

  if [ -n "$missing_labels" ]; then
    warn "not installed, so the matching unit lines stay inert:${missing_labels}.
     Install with: brew install${missing_formulae}"
  else
    ok "all four brew zsh helpers present (autosuggestions, completions, fzf, autojump)"
  fi
}

# One line into the real .zshrc, inside macboot's fence. ensure_block writes the file
# if absent and touches nothing outside the markers, which is what makes this safe
# against a .zshrc that already has 200 lines in it.
hook_zshrc() {
  local zdot rc ref
  zdot="$(zdot_dir)"
  rc="$zdot/.zshrc"

  if [ "$zdot" != "$MACBOOT_HOME" ]; then
    log "ZDOTDIR is $zdot, so the fence goes in $rc (not $MACBOOT_HOME/.zshrc)"
  fi

  # $SHELL_CFG_DIR is honoured in BOTH branches. An earlier version hardcoded
  # "$HOME/.config/macboot/zshrc" here while link_configs honoured the variable, so
  # `SHELL_CFG_DIR=... 20-shell.sh` linked into one place and sourced another, and
  # because the fence uses `[[ -r ... ]]` the mismatch was silent: all-green, nothing
  # loaded.
  if [ "$MACBOOT_HOME" = "${HOME:-}" ] &&
    [ "$SHELL_CFG_DIR" = "$MACBOOT_HOME/.config/macboot" ]; then
    # Literal, unexpanded $HOME on purpose: this string is code for a future zsh to
    # evaluate, not a path for this bash to resolve. shellcheck cannot tell the two
    # apart and offers to "fix" it into the real home directory, which is exactly what
    # must not be baked in -- the same dotfile is used under other accounts.
    # shellcheck disable=SC2016
    ref='"$HOME/.config/macboot/rc.zsh"'
  else
    ref="\"$SHELL_CFG_DIR/rc.zsh\""
  fi

  # if/then rather than `[[ ... ]] && source ...`: as the last line of the block the
  # && form leaves $? = 1 whenever the file is absent, and a themed prompt reads that
  # as "the previous command failed" on the first prompt of every shell.
  ensure_block "$rc" shell <<EOF
# Managed by macboot (scripts/20-shell.sh). Edits inside this fence are lost on the
# next run. Put your own config in ~/.config/zsh/conf.d/*.zsh -- one file per tool,
# so this file never has to grow again. Nothing else belongs in this file: even the
# prompt is a unit (90-p10k.zsh), and a file of yours with the same name replaces it.
if [[ -r $ref ]]; then
  source $ref
fi
EOF
}

# ---------------------------------------------------------------------------

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
  done

  step "shell: login shell"
  report_login_shell

  step "shell: shipped zsh units"
  check_syntax
  link_configs
  make_user_conf_dir
  check_support_files

  step "shell: hook into .zshrc"
  hook_zshrc

  summary "shell"
}

main "$@"
