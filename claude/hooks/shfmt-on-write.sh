#!/usr/bin/env bash
# claude/hooks/shfmt-on-write.sh -- PostToolUse hook: format a shell file Claude just
# wrote, but ONLY where the project has declared how it wants shell formatted.
#
# This lives in a file rather than inline in settings.json for two reasons: it needs a
# loop, and as a file it is linted by tests/lint.sh like everything else here. A hook
# that runs on every edit in every repository is exactly the code that should not be an
# unreviewable JSON one-liner.
#
# WHY THE .editorconfig GATE. The previous version ran `shfmt -i 2 -ci -w` on any *.sh
# Claude touched, anywhere, because settings.json is a GLOBAL user setting. Edit one
# line of a tab-indented script in an unrelated repo and the whole file was silently
# reindented to 2 spaces -- a one-line diff became a whole-file diff, in someone else's
# project, with no indication which tool did it. For a bootstrap other people install,
# that is not a nicety, it is damage.
#
# So: no explicit formatting flags, and no action unless an .editorconfig exists at or
# above the file. shfmt reads .editorconfig on its own when it is given no parser or
# printer flags (they take precedence and disable it), so the project's own declared
# indent wins and macboot imposes nothing. A repo that has not said what it wants is
# left completely alone, which is the correct default for a global hook.
#
# Exits 0 on every path. A formatter is not a gate, and a non-zero exit here would
# surface as a tool error on an edit that actually succeeded.
set -u

command -v jq >/dev/null 2>&1 || exit 0
command -v shfmt >/dev/null 2>&1 || exit 0

# The hook payload arrives on stdin as JSON.
f="$(jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
[ -n "$f" ] || exit 0
[ -f "$f" ] || exit 0

case "$f" in
  *.sh | *.bash) ;;
  *) exit 0 ;;
esac

# Walk up looking for an .editorconfig. `root = true` is shfmt's problem, not ours --
# we only decide whether the project has an opinion at all.
d="$(cd "$(dirname "$f")" 2>/dev/null && pwd)" || exit 0
while [ -n "$d" ] && [ "$d" != "/" ]; do
  if [ -f "$d/.editorconfig" ]; then
    shfmt -w "$f" >/dev/null 2>&1 || true
    exit 0
  fi
  d="$(dirname "$d")"
done

exit 0
