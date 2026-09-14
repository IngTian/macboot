# 10-history.zsh — shell history.
#
# A zsh with no history config keeps HISTSIZE=30 in memory and SAVEHIST=0, i.e. it
# writes nothing to disk at all. The shell looks fine until the first new window.

HISTFILE="${HISTFILE:-${ZDOTDIR:-$HOME}/.zsh_history}"
HISTSIZE=200000
SAVEHIST=200000

setopt EXTENDED_HISTORY     # timestamp + duration per entry, needed to age it out
setopt SHARE_HISTORY        # new entries visible in already-open windows
setopt HIST_IGNORE_ALL_DUPS # keep only the newest copy of a repeated command
setopt HIST_IGNORE_SPACE    # a leading space keeps a token/secret out of the file
setopt HIST_REDUCE_BLANKS
setopt HIST_VERIFY     # `!!` expands onto the line for review, does not run blind
setopt HIST_FCNTL_LOCK # locked writes; several shells appending unlocked to the
# same file on APFS interleave and truncate entries
