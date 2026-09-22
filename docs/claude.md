# Claude Code

What's worth giving your agent, and where each thing belongs. This is the highest-leverage
part of this repo and the least finished, so read it as a working position rather than a
recommendation I've held for years.

Nothing here is installed for you. [`claude/settings.json`](../claude/settings.json) is a
reference to copy from, not a file to symlink — see [the one thing not to
symlink](#the-one-thing-not-to-symlink).

## Four mechanisms, and picking the wrong one is the usual mistake

| mechanism | loads | use for |
|---|---|---|
| `~/.claude/CLAUDE.md` | **every session, always** | who you are, how you want to be advised. Keep it short. |
| `~/.claude/rules/*.md` | every session, or **only for matching files** | tooling conventions. `paths:` frontmatter means a Python rule costs nothing until a `.py` file is touched. |
| Skills | **on demand**, when relevant | multi-step procedures. A checklist is a skill, not a rule. |
| Hooks | at a fixed lifecycle event, **unconditionally** | anything that must actually happen. CLAUDE.md is context, not enforcement. |

The distinction that matters: **CLAUDE.md and rules are context — Claude reads them and
tries. A hook is enforcement.** If something must run before every commit, a line in
CLAUDE.md asking nicely is the wrong tool.

Two facts worth knowing, both from the [docs](https://code.claude.com/docs/en/memory):
`@path` imports in CLAUDE.md **do not save context** — imported files load at launch too, so
splitting is organisation, not economy. And a path-scoped rule genuinely does save context,
because it isn't loaded until a matching file is read.

## Prefer `~/.claude/rules/` over a big CLAUDE.md

For tooling conventions specifically. Three reasons:

1. **Path-scoping.** A Python convention loaded only when a `.py` file is touched costs
   nothing the rest of the time. A CLAUDE.md is in context on every session forever.
2. **No collision with your personal file.** `~/.claude/CLAUDE.md` is where *you* live —
   profile, preferences, how to talk to you. Tooling conventions in the same file mix private
   with shareable, and then you can't share either.
3. **They're user-scope**, so they apply to every project on the machine and load without the
   external-import approval dialog that project-level imports trigger.

Keep each under ~200 lines. Adherence drops as files grow, which is the documented behaviour
and also just true.

### The conventions worth writing down

These are the ones I'd otherwise retype every session. Each is ~10 lines.

```markdown
---
paths: ["**/*.py", "**/pyproject.toml", "**/requirements*.txt"]
---
# Python: uv owns everything

- `uv` is the interpreter manager AND the package manager. Never `pip install`,
  never conda, never a bare `python -m venv`.
- Per project: `uv venv` / `uv sync`. Never a global environment.
- `uv.lock` is committed. The lock is the reproducibility.
- `python` and `python3` resolve to `~/.local/bin` (uv's shims). If they resolve
  anywhere else, PATH is wrong — fix that rather than working around it.
```

The others, same shape: **shell** — anything that may run before Homebrew exists is bash 3.2,
so no `declare -A`, no `${var,,}`, no `mapfile`; `shellcheck` and `shfmt -i 2 -ci` gate
everything. **zsh config** — one file per tool in `~/.config/zsh/conf.d/`, never append to
`.zshrc`; respect the 50 boundary (see [`docs/shell.md`](shell.md)). **git** — never
`git config --global` against a symlinked config, it follows the link and rewrites the file in
the checkout; use `git config --file` and name the destination. **Toolchains** — the table in
[`docs/tools.md`](tools.md), stated as rules: uv not pip, brew go not goenv, rustup not brew
rust.

Every one of those is a decision this repo actually made and got bitten by, which is the only
reason to trust them over whatever sounds reasonable.

## Permissions: the allowlist is the highest-value part

An allowlist is pure recurring value — it pays on every session, and it's the one thing here
with no maintenance cost at all. The shape that works:

**Allow reads and analysis outright.** `git status`, `git diff`, `git log`, `git show`, `ls`,
`rg`, `jq`, `shellcheck`, `shfmt`, `bash -n`, `brew list`, `brew info`, `defaults read`.
None of these can change anything, and prompting for them trains you to click through
prompts, which is worse than not prompting.

**Ask for the things that change your machine.** `sudo`, `brew install`/`uninstall`,
`defaults write`/`delete`, `git push`, `git commit`.

**Deny what you'd never want, even from yourself.** Every spelling of `rm -rf` (there are ten
— `-rf`, `-fr`, `-Rf`, `-fR`, `-r -f`, `--recursive --force`, …), force-push in all its forms,
`git reset --hard`, `git clean -fd`, `git filter-branch`, `dd`, `mkfs`, `diskutil erase`,
`chmod -R 777`. Plus reads of `.env`, `id_rsa`, `id_ed25519`, `.netrc` — an agent shouldn't
have your keys in context by accident.

The deny list is worth over-specifying: flag spellings are cheap to enumerate and a single
gap is the whole point of the list.

## Plugins and skills: recommend, don't prescribe

I install exactly one plugin, `superpowers` from `anthropics/claude-plugins-official`, which
brings brainstorming, systematic-debugging, TDD and verification-before-completion. The
useful ones in practice are **brainstorming** (before writing code, not after) and
**verification-before-completion** (evidence before claiming something passes).

I'd rather under-install here. A plugin you haven't lived with for a month is a plugin whose
failure modes you don't know, and the cost of a bad one is that it fires on work where it
doesn't belong.

## The one thing not to symlink

`~/.claude/settings.json`. **Claude Code writes to it** — a theme, a model, plugin
registrations, a permission you granted once. Symlink it into a checkout and those writes land
in your working tree: `git status` goes dirty for reasons you didn't cause, `git pull`
conflicts, and machine-specific permissions sit in a repo one `git commit -a` from
publication.

So: **symlink what the tool only reads, copy what the tool writes.** `~/.claude/rules/*.md`
are read-only to Claude Code and can be symlinked, which is how convention updates arrive.
`settings.json` gets copied once and then belongs to you.

`settings.local.json` is machine-private by design — trusted directories, one-off allows.
Never commit it; `git/gitignore` in this repo has `**/.claude/settings.local.json` for exactly
that reason.
