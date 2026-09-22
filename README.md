# macboot

**A bracket of tools and conventions I use to develop on a Mac, written down.**

Not an installer. There is no `make install`, no bootstrap script, nothing that mutates your
machine. It used to be all of those — see [Why this stopped being a
script](#why-this-stopped-being-a-script) — and deleting them made it more useful, not less.

## How to use it

Read [`docs/tools.md`](docs/tools.md) and install what you want. Or, more likely:

> Read the docs in this repo and set my Mac up accordingly. Check what I already have
> before installing anything, skip whatever I've already solved differently, and tell me
> what you skipped and why.

An agent doing that beats a script, and the reason is specific: a script executes a fixed
plan against an unknown machine, which is where essentially all of this repo's historical
bugs came from — `brew shellenv` already in `.zprofile`, nvm already sourced, a `~/src` that
the author had deleted. An agent looks first and adapts. It is the better tool for the job,
so this repo stopped trying to be the worse one.

## What's here

| | |
|---|---|
| [`docs/tools.md`](docs/tools.md) | The tools, and **why each one** over the obvious alternative |
| [`docs/shell.md`](docs/shell.md) | A zsh layout where `.zshrc` is one line and never grows |
| [`docs/claude.md`](docs/claude.md) | Conventions, rules, plugins and permissions worth giving your agent |
| [`docs/manual.md`](docs/manual.md) | The things that stay human — and why automating them is worse |

Four directories are **reference configs**, not documentation. Copy them, symlink them, or
read them and write your own:

| | |
|---|---|
| `shell/` | The loader and eleven zsh units `docs/shell.md` describes |
| `git/` | A `gitconfig` and a global `gitignore` |
| `claude/` | A `settings.json` with a permission allowlist and one hook |
| `Brewfile`, `Brewfile.optional` | `brew bundle --file Brewfile` if you want the lot in one command |

## What this is not

- **Not a dev-env platform.** It does not manage drift, pin toolchains, or reproduce a
  machine. nix, devbox and mise do that, properly, and this is not competing with them.
- **Not a dotfiles manager.** No stow, no chezmoi, no symlink farm. Four directories you can
  read in ten minutes.
- **Not neutral.** Every recommendation here is one person's, on Apple Silicon, on current
  macOS. Where a choice is taste rather than reasoning, it says so.

## Why this stopped being a script

macboot was ~4,700 lines of bash: ten idempotent modules, a dry-run mode asserted on the
filesystem, a double-run test proving `changed=0`, CI over five jobs. It worked. An
adversarial audit of it produced 71 reproduced defects, and running it on a real machine
found more — including two where **macboot had become the thing it was written to prevent**,
appending a duplicate `brew shellenv` to `.zprofile` and a duplicate `nvm.sh` source to
`.zshrc`, which its own README cited as the reason it existed.

The arithmetic is what settled it. A new Mac every three years, against maintenance for
4,700 lines of shell that has to be right about someone else's software. The install was
never the valuable part; the **decisions** were — and a decision written down costs nothing
to maintain and can be handed to an agent, a colleague, or yourself in two years.

What survived is what pays off more than once: the zsh layout, because it makes per-unit
startup cost measurable (which is how a 943 ms nvm load and a 297 ms misplaced `compinit`
were found), and the reasoning behind each tool choice, because that is the part you cannot
rederive from a Brewfile.
