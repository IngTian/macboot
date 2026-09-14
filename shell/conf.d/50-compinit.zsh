# 50-compinit.zsh — THE BOUNDARY. compinit runs here, exactly once.
#
# Files numbered below 50 may add to $fpath. Files numbered above 50 may rely on
# completions existing. No other drop-in should ever call compinit: a second call
# re-registers every completion function and, together with zsh-autosuggestions,
# shows up as suggestions being accepted twice per keystroke.

autoload -Uz compinit

# -i, not the default and not -u. Without a flag, compinit's security audit finds a
# group-writable directory in $fpath and asks an interactive question:
#
#     Ignore insecure directories and continue [y] or abort compinit [n]?
#
# Every new shell then BLOCKS on that prompt, and when it aborts no dump is written,
# so the full audit — and the prompt — recurs forever. Reproduced with a
# group-writable fpath entry. It is not exotic: Homebrew's share/zsh-completions is
# owned by the installing user rather than root (verified: drwxr-xr-x zetian admin),
# so a SECOND account on the same Mac, or the classic group-writable /usr/local
# layout on Intel, hits it on every shell.
#
# -i drops the offending directories instead of asking about them. That is the safe
# direction of the trade: an insecure directory is one whose completion functions
# another user could edit, and completion functions are code. The cost is that brew
# completions can go quietly missing, so `MACBOOT_ZSH_COMPAUDIT=1 exec zsh` reports
# what was dropped rather than leaving you to wonder.
#
# -C skips the audit entirely and trusts the existing dump. The audit stats every
# file in $fpath and costs a measurable 150-300 ms with brew's site-functions on a
# cold cache, so the full check runs once a day and the cheap path runs the rest of
# the time. `mh+24` = modified more than 24 hours ago.
_macboot_zcompdump="${ZDOTDIR:-$HOME}/.zcompdump"
() {
  local -a stale
  stale=($_macboot_zcompdump(N.mh+24)) # exists, regular file, older than a day
  if [[ ! -s $_macboot_zcompdump ]] || (($#stale)); then
    compinit -i -d "$_macboot_zcompdump"
  else
    compinit -C -i -d "$_macboot_zcompdump"
  fi
}

if [[ -n ${MACBOOT_ZSH_COMPAUDIT:-} ]]; then
  autoload -Uz compaudit
  () {
    local -a bad
    bad=($(compaudit 2>/dev/null))
    if (($#bad)); then
      print -u2 "  ! zsh skipped $#bad insecure completion dir(s); fix with:"
      print -u2 "      compaudit | xargs chmod g-w,o-w"
    else
      print -u2 "  ok all completion directories are secure"
    fi
  }
fi
unset _macboot_zcompdump

zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}' # lowercase input matches Foo
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path "${ZDOTDIR:-$HOME}/.zcompcache"
