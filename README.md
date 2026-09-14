# macboot

```
 _______________________________
< one clone, one make. moo.     >
 -------------------------------
        \   ^__^
         \  (oo)\_______
            (__)\       )\/\
                ||----w |
                ||     ||
```

Takes a brand-new macOS install to a working dev machine with one `git clone` and one
`make`. It installs a toolchain and writes config. That is all it does.

The *second* run is the point: it reports `changed=0` and means it.

## Quickstart

```sh
git clone https://github.com/IngTian/macboot.git
cd macboot
make plan     # dry run: every change printed as `would ...`, nothing written
make all      # do it
make apps     # print the GUI apps you are missing (it never installs one)
```

Read `make plan` before `make all` — it is the full transcript, not a formality. If a
line in it looks wrong, it would have been wrong. `make help` lists the rest.

One module at a time: `make module M=40-node`, or `DRY_RUN=1 bash scripts/40-node.sh`.
Every module is standalone, runnable in any order, and safe to re-run.

## What runs

| | |
|---|---|
| `00-preflight` | inspects the machine, changes nothing |
| `10-brew` | Homebrew + the `Brewfile` formulae. Never upgrades anything |
| `20-shell` | zsh config: `shell/rc.zsh` plus eight units in `shell/conf.d/` |
| `30-python` | uv, and one pinned CPython |
| `40-node` | nvm + node LTS — and node visible to *non-interactive* shells too |
| `50-git` | git config, and it offers to set your name and email |
| `55-github` | offers `gh auth login` — browser sign-in, and uploads an SSH key |
| `70-claude` | Claude Code settings and one plugin |
| `80-mytools` | four tools of mine, each asked for separately, all default to no |
| `99-apps` | prints the GUI apps that are missing |

**It asks before it does the personal bits.** Your git identity, GitHub sign-in and each of
my four tools are questions, not assumptions — and every one of them is *skipped* rather
than guessed when there is no terminal to ask at, when you pass `--yes`, or during a dry
run. So `curl … | bash` and CI stay unattended and acquire nothing you did not ask for.

`55-github` does not roll its own `ssh-keygen`: `gh auth login --git-protocol ssh` already
creates a key if you have none and uploads the public half itself, so there is nothing to
paste into a browser. Key **custody** — having a second copy — is still yours, and
`notes/MANUAL-STEPS.md` says so plainly rather than pretending otherwise.

`make optional` adds the nice-to-have formulae from `Brewfile.optional`. Both Brewfiles
carry one line of *why* per formula — read those instead of a list here that would rot.

Everything macboot **cannot** do — the Raycast ⌘-Space swap, App Store sign-in, licences
and 2FA, `chsh`, SSH key custody, setting up a backup — is in
[`notes/MANUAL-STEPS.md`](notes/MANUAL-STEPS.md), each with the reason it is not scripted.
Work through it once after `make all`.

## GUI apps are listed, never installed

`apps.tsv` holds VS Code, iTerm2, Claude Code, Chrome, Docker Desktop, Raycast and
Obsidian. `make apps` says which are missing and hands you the exact
`brew install --cask` line for each. A cask collides with an app you dragged in from a
.dmg, casks get renamed and relocated on someone else's schedule, and an unattended run
that pops a licence dialog is a worse first five minutes than a list. Printing a command
also removes any need for `mas`.

## Your `.zshrc` gets one line, forever

macboot appends one fenced `source` line and never needs another.

```
~/.zshrc                          one macboot fence. Never grows.
  └── shell/rc.zsh                the loader
      ├── shell/conf.d/*.zsh      00-path 10-history 20-options 30-fpath
      │                           50-compinit 60-keys 70-aliases 80-plugins
      └── ~/.config/zsh/conf.d/*.zsh    yours. macboot never writes here.
```

Both directories are merged and sorted **by filename**, so your `40-work.zsh` runs before
macboot's `50-compinit.zsh`. One rule: **below 50 may add to `$fpath`; 50 runs `compinit`,
once; above 50 may rely on completions.** That is the only real ordering constraint in a
zsh config, and the number makes it visible instead of tribal knowledge.

A file of yours with the same name as one of macboot's **wins** — yours loads second. So
replacing the aliases is a file, disabling them is an *empty* file, and you never edit
anything inside this checkout to change what your shell does.

Why bother: the machine this replaces had a 242-line `.zshrc` in which `~/.local/bin` was
prepended twice and conda base twice, because nvm, conda, gcloud, oh-my-zsh, p10k, bun and
opencode had each appended a block over two years and nothing ever removed one. No single
line was wrong; the file was.

## What it will never do

- **No secrets.** No keys, tokens or credentials, encrypted or otherwise.
- **No cask installs.** See above.
- **No MDM removal.** Preflight warns on a managed Mac and continues, because a managed
  Mac may withhold the admin rights the Homebrew installer needs.
- **No system preferences.** No Dock, Finder, trackpad or key-repeat `defaults`. An earlier
  version wrote 27 of them; they are your taste to set, and `defaults(1)` talks to cfprefsd,
  which ignores `MACBOOT_HOME` — so that was also the one module no test could sandbox.
- **Not a backup or a migration tool.** It sets up a new Mac and never inspects an old one.

And the honest caveat: this is one person's taste. The aliases in `70-aliases.zsh` are what
*I* like, not advice. Fork it, or drop a file of your own on top.

## Design notes

**One tool per language, and the alternatives stay off the machine.** uv for Python (no
pyenv, no conda, no bare `venv`); nvm for node, because several versions resident at once
is the one thing it is genuinely good at; brew `go` and no goenv, since Go 1.21's
`toolchain` directive fetches whatever a project asks for and a version manager on top is
duplicated SDKs solving a solved problem; cmake + ninja for C/C++; rustup for Rust *if*
you add it, which is why `rust` is absent from the `Brewfile` — brew's `rust` and rustup
fight over the same `cargo`. Two version managers for one language is how a shell resolves
the wrong interpreter and does not tell you. No Nix, Ansible or chezmoi either: the thing
that runs before a package manager exists should not need one.

**Shell startup is measured, not argued.** `zprofile` (an alias for
`MACBOOT_ZSH_PROFILE=1 exec zsh`) prints the per-unit cost, so "my shell got slow" has an
answer. The plugins dominate; the glob and the eight `source` calls are noise.

**Two writers bypass `run()`.** Every mutation goes through one `run()` helper that
consults one `DRY_RUN` flag — except `ensure_block` and `link_once` in
`lib/common.sh`, which write through shell redirects and so check `DRY_RUN` themselves and
update the same counters. `ensure_block` is the one that touches your `.zshrc`. Grepping
for `run()` will not find them, which is why
[`tests/dry-run-purity.sh`](tests/dry-run-purity.sh) proves a dry run is inert by
asserting on the *filesystem* rather than on the transcript.

## Requirements

**Apple Silicon only** — `00-preflight.sh` refuses anything else, because `/opt/homebrew`
is hardcoded rather than detected. **Current macOS**, with no accommodations for older
versions — which is why `git` and `jq` are absent from the `Brewfile`: macOS ships both, and
brew's are one minor version ahead of Apple's.

Plus the Xcode Command Line Tools, which are a hard prerequisite (preflight dies without
them), and `/bin/bash` — the scripts are bash 3.2 compatible because that is what a fresh
Mac ships and this runs before Homebrew exists.

MIT — see [LICENSE](LICENSE).
