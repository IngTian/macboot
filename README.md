# macboot

`macboot` takes a fresh macOS install to a working dev machine with one `git clone`
and one `make`. Re-running it changes nothing and says so — `changed=0` on the
second run is the whole point.

These are tools I find useful and use personally. Some are must-have — the
toolchain everything else assumes, and the scripts install those without asking.
Some are nice-to-have, and for those you decide: they sit in a separate file behind
a separate target. I am not claiming this is how you should set up a Mac. It is how
I set up mine, written down so I do not have to remember it again.

## Quickstart

```sh
git clone https://github.com/IngTian/macboot.git
cd macboot
make plan     # dry run: prints every change, makes none
make all      # do it
```

Run `make plan` first, and read it. It is not a formality — it is a full transcript
of every mutation, printed as `would <command>`, because mutations route through one
`run()` helper that consults one `DRY_RUN` flag. If a line in `make plan` looks wrong,
it would have been wrong.

Three helpers in `lib/common.sh` are the exception, and it is worth knowing which:
`ensure_block`, `link_once` and `defaults_set` write with shell redirects, which are
not commands `run()` can invoke. They check `DRY_RUN` themselves and update the same
counters, so `--plan` and the change count stay honest — but "grep for `run()`" will
not find them, and `ensure_block` is the one that edits your `.zshrc`. The proof that
a dry run is inert is [`tests/dry-run-purity.sh`](tests/dry-run-purity.sh), which
asserts on the *filesystem* rather than the transcript, for exactly this reason.

Individual modules are runnable on their own, in any order, as often as you like:

```sh
DRY_RUN=1 bash scripts/40-node.sh
bash scripts/40-node.sh
```

Nothing in the bootstrap inspects your repositories or refuses to proceed because of
them. If you are *retiring* a Mac rather than setting one up, that is a different job
and a separate tool — [`check-unpushed.sh`](#migrating-off-a-mac-check-unpushedsh),
below.

## Automated / listed / manual

| | What | Where |
|---|---|---|
| **Automated** | Homebrew + formulae, zsh drop-ins, uv, nvm + node LTS, Go (via brew), git config, macOS defaults, Claude Code settings and plugins | `scripts/*.sh` |
| **Listed only** | GUI apps — VS Code, iTerm2, Claude Code, Docker Desktop, Raycast, Obsidian, Chrome | `apps.tsv`, `make apps` |
| **Manual** | Raycast's ⌘-Space swap, Xcode CLT's GUI installer, App Store sign-in, licences and 2FA, `chsh`, selecting the screensaver, Full Disk Access, **SSH key custody**, **setting up a backup** | [`notes/MANUAL-STEPS.md`](notes/MANUAL-STEPS.md) |

GUI apps are printed, never installed. `make apps` tells you what is missing and
gives you a paste-ready `brew install --cask ...` line per app. Casks get renamed
and relocated; a bootstrap that installs them fails on someone else's schedule,
and printing a command removes any need for `mas` as well.

Anything in the manual column is there because I tried to automate it and the
automation was worse than the two clicks. Each entry in `notes/MANUAL-STEPS.md`
says why.

## Toolchain decisions

One choice per language, and the alternatives are not installed — half the value
here is what is *absent*, because two version managers for one language is how you
get a shell that resolves the wrong interpreter and does not tell you.

| | Choice | Why |
|---|---|---|
| Python | **uv** | One tool for interpreters, venvs and locking. No pyenv, no conda, no bare `venv`. |
| Node | **nvm** | I need several versions resident at once, which is the one thing nvm is actually good at. |
| Go | **brew `go`**, no goenv | Since Go 1.21 the `toolchain` directive in `go.mod` fetches the version a project asks for. A version manager on top of that is duplicated SDKs solving a problem the compiler already solved — goenv was holding 20 GB of them on the machine this repo replaces. |
| Rust | **rustup, but not installed** | Nothing in the must-have set needs Rust, so macboot does not install it — it only stays out of the way, keeping `rust` out of the Brewfile and leaving `~/.cargo/bin` on PATH for when you add it. When you do, use rustup: `brew install rust` and rustup fight over the same `cargo`/`rustc`. The one-liner is in [`notes/MANUAL-STEPS.md`](notes/MANUAL-STEPS.md). |
| C/C++ | **cmake + ninja**, nothing else | Enough to build other people's projects, which is all I do. No vcpkg, no Conan — a package manager for a language I write zero lines of. |
| Java | **none** | Not installed. If I need it, that is a decision for that day. |
| Framework | plain shell + Brewfile + Makefile | No Nix, no Ansible, no chezmoi. The thing that runs before a package manager exists should not need a package manager. |

`shellcheck` and `shfmt` are in the must-have tier and not negotiable: this repo
*is* shell, and both run in CI from the first commit.

## Your `.zshrc` gets one line, forever

The shell config is a **drop-in directory**, not a block appended to your `.zshrc`.
macboot adds exactly one fenced `source` line and never needs another.

```
~/.zshrc                     one macboot fence. Never grows.
  └── shell/rc.zsh           ~20 lines: the loader
      ├── shell/conf.d/      macboot's units, numbered
      │     00-path  10-history  20-options  30-fpath
      │     50-compinit   ←── compinit runs here, once
      │     60-keys  70-aliases  80-plugins
      └── ~/.config/zsh/conf.d/*.zsh      yours. macboot never writes a unit here.
```

**One rule:** units numbered **below 50** may add to `$fpath`; units **above 50** can
rely on completions existing. That is the only real ordering constraint in a zsh
config, and the number makes it visible instead of tribal knowledge.

A unit of yours with the same filename as one of macboot's **wins**, because yours
loads second. So replacing macboot's aliases is a file, and disabling them is an empty
file — you never edit anything inside this checkout to change what your shell does.

Why bother: the machine this replaces had a 242-line `.zshrc` in which `~/.local/bin`
was prepended **twice** and conda base **twice**, because nvm, conda, gcloud,
oh-my-zsh, p10k, bun and opencode had each appended a block over two years and nothing
ever removed one. No single line was wrong; the file was. An append-only file that N
installers all hold a write lock on ends up that way by construction.

"Many small files must be slow" is the obvious objection, so it is measured rather than
argued. All 9 units cost **54 ms**, of which 40 ms is zsh-autosuggestions + fzf and
12 ms is a cold `compinit`; the glob, the merge and the 9 `source` calls together are
under 1 ms. The `.zshrc` it replaces took 1,530 ms.

```sh
MACBOOT_ZSH_PROFILE=1 exec zsh   # per-unit startup cost, so "my shell got slow" is a
                                 # measurement instead of a guess
```

## Tiers

**Must-have** — `Brewfile`, installed by `make all` (or `make module M=10-brew` alone). The toolchain everything else
assumes:

> git · gh · zsh-autosuggestions · zsh-completions · fzf · tmux · htop · autojump ·
> ripgrep · jq · gnupg · go · cmake · ninja · shellcheck · shfmt · pre-commit

plus **uv** and **nvm** via their own installers, because their brew
formulae are either absent or a known conflict.

**Nice-to-have** — `Brewfile.optional`, installed only if you run `make optional`.
Your call; skipping it costs you nothing structural:

> fd · bat · tree · eza · yq · direnv · zoxide · ollama · tectonic · redis ·
> mkcert · p7zip · poppler · gifsicle · cowsay

**My own tools** — `make mytools`. Three are public and get built from source:
`witness` (Go), `daylogs` (Python), `manifold` (a Swift screensaver — the build is
automated, selecting it in System Settings is not). A fourth is private; the script
detects that you have no access, says so, and does not fail the run.

**Listed only** — `apps.tsv`, printed by `make apps`. See the table above.

## Migrating off a Mac: `check-unpushed.sh`

`check-unpushed.sh` is for **migrating off** a Mac, not for setting one up. It is not
a bootstrap step and nothing in `scripts/` calls it: a fresh machine has no
repositories to check, and a published bootstrap that refuses to proceed because a
stranger has an unpushed commit is a hostile default. Run it yourself, before you
wipe anything:

```sh
make check                      # human report, always exits 0
bash check-unpushed.sh --verify # exits non-zero while anything is at risk
bash check-unpushed.sh --bundle /Volumes/somewhere-else
```

`--verify` exits non-zero if **any** of these is true of **any** repo it finds:

- `origin` does not resolve — it is contacted, not read out of `.git/config`
- `git stash list` is not empty
- a local branch has no upstream, or is ahead of it, or its upstream is gone
- `HEAD` is detached at a commit no remote branch contains
- a tag points at a commit no remote branch contains
- a tracked file is modified — in the checkout **or in any linked worktree**
- …or it could not scan everything it was pointed at

That last one matters as much as the rest. "I found nothing" and "I could not look"
used to share an exit code, so a mistyped root, a symlinked root or a bad
`MACBOOT_REPO_DEPTH` all reported *nothing to lose* about a tree it had never opened.
A green result now means it looked everywhere.

The finding list is not arbitrary. Three facts about git are the whole reason:

**A stash is not a commit.** It is a dangling commit held by one reflog entry under
`refs/stash`. `git push` will never send it, no branch contains it, and nothing
outside that reflog remembers it exists. On the disk this repo was written for, two
stashes carried the *only* remaining record of branches that existed nowhere else —
delete the repo and the work is not "unpushed", it is gone. So an empty stash list
is a precondition, not a nicety.

**A configured remote can be deleted without git noticing.** `origin` is a URL in
`.git/config`, and everything under `refs/remotes/origin/` is a local cache of the
last time you talked to it. Delete the repository on the server and nothing local
changes: `git status` still says *up to date with 'origin/main'*, `git branch -vv`
still prints an upstream, and you find out at the next push — which, if you were
about to reclaim disk space, is after. One repo here holds 189 commits whose remote
no longer exists and looks perfectly safe by every local signal. That is why the
check does a live lookup against the remote instead of believing the config.

**`git push` does not carry tags, and a detached HEAD is on no branch at all.** Both
are commits reachable from nothing a branch-based check looks at. Running this against
the machine it was written for, that is not theoretical either: it found 9 unpushed
`archive/*` tags in one repo and 4 release tags in another.

I wrote it because a worktree on that machine was already lost to `/private/tmp`
cleanup, taking commits that existed in exactly one place. This is not a
hypothetical failure mode; it is a repeat of one — and the tool still reports that
dangling registration today, along with an uncommitted edit in a linked worktree that
`git status` in the main checkout says nothing about.

On a genuinely fresh machine you will never run this. That is the point of it not
being a bootstrap step.

## `make help`

Generated from the real target list, not written by hand:

```
$ make help
macboot — targets

Start here
  help           this list
  plan           dry run: print every change, make none  <- start here
  all            every module in order, 00 -> 99 (resumes; --restart to redo)

Tiers
  optional-plan  dry run of `optional`
  optional       Brewfile.optional — the nice-to-have formulae
  mytools-plan   dry run of `mytools`
  mytools        build my own tools; skips the private one
  apps           print the GUI apps that are missing, with paste-ready commands

Gates and quality
  check          migrating off a Mac? non-zero while any commit exists only on this disk
  lint           shellcheck + shfmt -d over every shell file in the tree
  fmt            rewrite every script with shfmt (the plan equivalent is `lint`)
  test           lint, bash -n, then the real tests: purity, bootstrap flow, idempotency

One module at a time
  module-plan    dry run of `module`
  module         run one module: make module M=40-node (also 40, node, 40-node.sh)

DRY_RUN=1 works on every target. ./bootstrap.sh --help lists all flags.
```

Every target is safe to re-run, and every target that changes the machine has a
`*-plan` twin that prints the same run as `would <command>` and changes nothing.

## What this deliberately does not do

- **No secrets.** No keys, no tokens, no credentials, not encrypted ones either.
  Nothing in this repo needs unlocking, and nothing in it can leak. SSH key custody
  is a real unsolved problem and `notes/MANUAL-STEPS.md` says so plainly instead of
  pretending a public repo can fix it.
- **No GUI installs.** Casks are listed, not installed. See above.
- **No MDM support.** If a Mac is managed, `00-preflight.sh` warns and continues.
  It will not strip a management profile: removing one violates the policy you
  agreed to, and Jamf reinstalls it anyway. Expect some `defaults` to be silently
  reverted on a managed machine — that is the MDM working, not macboot failing.
- **Not a backup tool.** `check-unpushed.sh` verifies that git commits exist
  somewhere other than this laptop. That is the entirety of its claim. It does not
  copy your photos, and a clean run of it is not a backup.
- **No personal layer.** No private overlay repo, no dotfiles submodule, no
  machine-specific branch. My personal setup stays manual on purpose, which is also
  why `memory/` is in `.gitignore` — that is structural, so that personal content
  has no path into a public repo at all.

## Requirements

macOS on Apple Silicon or Intel (Homebrew's prefix is detected, not hardcoded),
the Xcode Command Line Tools, and `/bin/bash`. The scripts are bash 3.2 compatible
because that is what a fresh macOS ships and this code runs before Homebrew exists.

## License

MIT — see [LICENSE](LICENSE).
