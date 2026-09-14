# macboot — the zsh loader. Sourced from ~/.zshrc by a macboot:shell fence.
#
# ~/.zshrc gets ONE line that points here and never needs another. Every setting
# lives in its own numbered file under conf.d/, so adopting a tool means adding a
# FILE and dropping one means `rm`.
#
# Why, concretely. The machine this repo was written on had a 242-line ~/.zshrc in
# which ~/.local/bin was prepended twice (lines 213 and 232) and conda base twice
# (lines 32 and 225), because nvm, conda, gcloud, oh-my-zsh, p10k, bun and opencode
# had each appended their own block over two years and nothing ever removed one. No
# single line was wrong; the file was the bug. An append-only file that N installers
# all hold a write lock on ends up that way by construction, so the fix has to be
# structural: give every tool its own file and stop appending.
#
# This file is never ~/.zshrc itself. 20-shell.sh only appends a fenced source line,
# because a published bootstrap that overwrites a stranger's ~/.zshrc destroys work
# it cannot see. Anything you want to keep goes outside the fence.
#
# Interactive-only: zsh reads ~/.zshrc for interactive shells, so nothing loaded from
# here is visible to `zsh -c '...'`. Exports a non-interactive shell must see (node,
# for Claude Code's hooks) belong in ~/.zshenv and are 40-node.sh's problem.

# Sourcing this twice runs compinit twice and double-registers zsh-autosuggestions'
# ZLE widgets, which shows up as suggestions being accepted twice per keystroke.
[[ -n ${MACBOOT_ZSHRC_SOURCED:-} ]] && return 0
MACBOOT_ZSHRC_SOURCED=1

# ${0:A:h} = this file's own directory with symlinks resolved, NOT $HOME/.config/...
# 20-shell.sh installs a symlink, so resolving it is what guarantees the drop-ins
# loaded are the ones from the same checkout as this loader. A hardcoded path reads a
# different repo's config when MACBOOT_HOME points at a scratch home (the double-run
# test) and reads nothing at all under a non-default ZDOTDIR.
_macboot_rc_dir=${0:A:h}

# Your own drop-ins. macboot never writes here, so nothing it does can clobber them.
: ${MACBOOT_ZSH_USER_DIR:=${XDG_CONFIG_HOME:-$HOME/.config}/zsh/conf.d}

# ---------------------------------------------------------------------------
# Load order
# ---------------------------------------------------------------------------
# Units from both directories are merged and sorted BY FILENAME, so your
# 40-work.zsh runs before macboot's 50-compinit.zsh. Sorting by full path instead
# would put every user file after every macboot file and make the numbers a lie.
#
# Two digits, always: the sort is lexical, so `9-foo.zsh` would run after
# `80-plugins.zsh`.
#
# The ONE ordering rule worth remembering:
#
#     below 50  ->  may add to $fpath        (completions are not loaded yet)
#     50        ->  compinit runs, once
#     above 50  ->  may rely on completions and on the final keymap
#
# No drop-in ever calls compinit itself. That is the only real ordering constraint
# in a zsh config, and the number makes it visible instead of tribal knowledge.
#
# Same basename in your directory WINS, because it is assigned second. That is the
# override mechanism: to replace macboot's aliases wholesale, write your own
# ~/.config/zsh/conf.d/70-aliases.zsh; to disable them, make that file empty. You
# never have to edit anything inside this checkout to change what your shell does.
typeset -A _macboot_units
for _macboot_f in $_macboot_rc_dir/conf.d/*.zsh(N) $MACBOOT_ZSH_USER_DIR/*.zsh(N); do
  _macboot_units[${_macboot_f:t}]=$_macboot_f
done

# `source` at the top level of a loop keeps the drop-ins in GLOBAL scope. Sourcing
# them from inside a function would make every `typeset -U path` in them
# function-local and silently undo it on return, which is why this loop is not
# wrapped in a helper despite the repetition below.
if [[ -n ${MACBOOT_ZSH_PROFILE:-} ]]; then
  # MACBOOT_ZSH_PROFILE=1 exec zsh  ->  per-unit cost, so "my shell got slow" is a
  # measurement instead of a guess. This is the payoff of one-file-per-concern.
  zmodload zsh/datetime
  typeset -F _macboot_t0 _macboot_total=0
  for _macboot_k in ${(ko)_macboot_units}; do
    _macboot_t0=$EPOCHREALTIME
    source $_macboot_units[$_macboot_k]
    printf '  %7.1f ms  %s\n' \
      $(((EPOCHREALTIME - _macboot_t0) * 1000)) $_macboot_k >&2
    _macboot_total+=$((EPOCHREALTIME - _macboot_t0))
  done
  printf '  %7.1f ms  TOTAL (%d units)\n' \
    $((_macboot_total * 1000)) ${#_macboot_units} >&2
  unset _macboot_t0 _macboot_total
else
  for _macboot_k in ${(ko)_macboot_units}; do
    source $_macboot_units[$_macboot_k]
  done
fi

unset _macboot_rc_dir _macboot_f _macboot_k
unset _macboot_units

# The last line must succeed. `set -e` is off in an rc, but a failing final command
# leaves $? non-zero and a themed prompt then renders an error marker on the very
# first prompt of every shell.
true
