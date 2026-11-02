# macboot

What I install on a new Mac, grouped by what it's for, and how I want it set up. One file, no
scripts: do §0 by hand, then go through the rest yourself or give it to Claude Code:

```sh
gh repo clone IngTian/macboot ~/devpro/ing/macboot && cd ~/devpro/ing/macboot && claude
```

> Set up this Mac from README.md. Look before you change anything: skip whatever is already
> installed or solved differently, and never upgrade what's there. Stop and hand me every 👤
> step. Finish with three lists: done, skipped (and why), left for me.

**Why there's no script.** This repo used to be ~4,700 lines of idempotent bash. Nearly
every bug it had was the same shape: a fixed plan run against a machine it hadn't looked at
(`brew shellenv` already in `.zprofile`, nvm already sourced). An agent looks first. The
decisions were always the valuable part. The scripted version is still in history at
`f71dd6f`.

| § | category | what |
|---|---|---|
| 0 | Bootstrap 👤 | CLT, Homebrew, PATH, gh, Claude Code |
| 1 | **Claude Code & AI** | Claude Code (essential), plugins, settings, witness, ollama |
| 2 | Terminal & shell | iTerm2, the CLI basics, zsh |
| 3 | Development | VS Code, git, languages, Docker, Chrome |
| 4 | Markets & research | TradingView, trading-desk, Kaggle, LaTeX, PDFs |
| 5 | Notes, tasks & life | Obsidian, TickTick, daylogs, Google Drive |
| 6 | Mac utilities | Raycast, Snipaste, AirStats, manifold, media CLIs |
| 7 | Chat, calls & remote | WeChat, Discord, Windows App |
| 8 | By hand 👤 | what stays human, and why |

## Rules for whoever runs this

- **Apple Silicon, current macOS.** `uname -m` must print `arm64` and
  `sysctl -n sysctl.proc_translated` must print `0`. A terminal running under Rosetta
  installs x86_64 everything without a warning. `/opt/homebrew` is assumed throughout.
- **Look, then act.** Check before every install and skip what exists. Never upgrade
  something as a side effect.
- **`brew install` below always means**
  `HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 brew install`.
  Without those three, installing a formula upgrades it, and its dependents, when they're
  already there. Not `brew bundle` either: it treats *outdated* as *missing*. Formulae are
  `--formula`, so a name can't resolve to a cask.
- **Apps: `brew install --cask <cask>` only if `/Applications/<bundle>` doesn't exist.** A
  cask over an app dragged in from a `.dmg` fails. The tables give the bundle name, which
  often isn't the app's name. Casks are installed one at a time and never from a bundle file.
- **Run each code block as one command.** Separate shell calls don't share variables or
  functions, so `v=…` or `nvm` set in one call is gone in the next.
- **Nothing gets appended to `~/.zshrc`, `~/.zprofile` or `~/.zshenv` unchecked.** `grep`
  first. Keep vendor installers out of rc files (`INSTALLER_NO_MODIFY_PATH=1`,
  `PROFILE=/dev/null`, `--no-modify-path`), and ignore the "add this to your `.zshrc`"
  advice they print. Apps append lines on first launch (Docker Desktop adds a PATH line to
  `~/.zprofile`), so look again then. PATH lines can stay where login shells read them;
  interactive lines (completions, aliases) belong in a §2 unit.
- **👤 means a person.** Passwords, browser logins, GUI dialogs, System Settings, which
  email goes where. Don't guess them and don't script around them.
- **No secrets in this repo.** Keys, tokens, licences and private config move from the old
  Mac by hand.

## 0. Bootstrap 👤

Each of these needs a person, in this order. First, two things from the old Mac before
anything writes over them:

- 👤 **iCloud:** sign in and turn on **Desktop & Documents** (System Settings → Apple ID →
  iCloud → iCloud Drive). Then wait for `~/Documents` to download. If you turn it on after
  something has written to `~/Documents`, iCloud files the local copy under a folder named
  after this Mac instead of merging it. daylogs and trading-desk live there.
- 👤 **`~/.ssh`:** copy the old Mac's (`chmod 700 ~/.ssh; chmod 600 ~/.ssh/id_*` without the
  `.pub` files). `gh auth login` below then uploads that key instead of generating a new one
  that the old Mac's copy would overwrite.

```sh
xcode-select --install     # 👤 dialog: Install, Agree, and wait until it's done. clang, git, the SDK
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"  # 👤 sudo password

# ~/.local/bin (uv, claude, the node links) on PATH for every zsh, and ahead of brew in login shells
grep -qs '\.local/bin' ~/.zshenv ||
  echo 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac' >> ~/.zshenv
grep -qs 'brew.*shellenv' ~/.zprofile ||   # Homebrew's installer may already have added one
  echo 'if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi' >> ~/.zprofile
grep -qs 'path=(~/.local/bin' ~/.zprofile ||
  echo 'typeset -U path; path=(~/.local/bin $path)   # path_helper and shellenv just pushed it behind brew' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"; export PATH="$HOME/.local/bin:$PATH"   # this shell too

brew install gh && gh auth login --git-protocol ssh    # 👤 browser; uploads ~/.ssh's key, or creates one
curl -fsSL https://claude.ai/install.sh | bash          # Claude Code, native: auto-updates, ~/.local/bin/claude
claude                                                   # 👤 browser login
```

👤 Then bring over from the old Mac, before anything below writes to them:
`~/.claude/settings.json`, `~/.claude/CLAUDE.md`, `~/.claude/memory/`, and the per-project
memory under `~/.claude/projects/`. §1 adds to `settings.json`, so copying it later would
undo that. If the username changed, fix the absolute paths inside it.

- Don't set `NONINTERACTIVE=1` for Homebrew. It switches to `sudo -n` and aborts on a fresh
  admin account.
- `shellenv` goes in `~/.zprofile`, which login shells read; `.zshrc` is interactive only.
  `~/.zshenv` is the one file every zsh reads, including the non-interactive ones that hooks
  and cron start. Without the `path=` line, `zsh -lc python3` finds brew's Python, not uv's.
- After a major macOS upgrade, `test -d "$(xcode-select -p)"`. The CLT receipt survives
  the upgrade; the directory sometimes doesn't, and the next `brew install` dies looking for
  clang.

## 1. Claude Code & AI

### Claude Code: essential

Installed in §0 with the native installer, which auto-updates. Not the cask: Homebrew installs
don't auto-update. Then:

```sh
claude plugin marketplace add anthropics/claude-plugins-official
claude plugin install superpowers@claude-plugins-official
claude plugin install frontend-design@claude-plugins-official
claude plugin marketplace add DietrichGebert/ponytail
claude plugin install ponytail@ponytail
```

ponytail's hooks run `node`. Until §3 links node into `~/.local/bin` they fail harmlessly;
restart Claude Code after §3.

- 👤 `adversarial-audit` is a local plugin with no remote, and it's read where it sits. Copy
  the old Mac's `~/devpro/adversarial-audit-plugin` to the same path (`settings.json` names
  it), then:
  `claude plugin marketplace add ~/devpro/adversarial-audit-plugin && claude plugin install adversarial-audit@ing-local`
- **Copy `~/.claude/settings.json` (§0), never symlink it.** Claude Code rewrites the file
  itself (plugin registrations, key order). If starting from scratch, it looks like this:
  - `effortLevel: xhigh` (also under `modelSettings`), `alwaysThinkingEnabled`,
    `enableWorkflows`, `skipWorkflowUsageWarning` and `ultracode`.
  - Allow `Bash`, `Read`, `Edit`, `Write` and `WebFetch`. Also allow `Skill(<name>)` and
    `Skill(<name>:*)` for the superpowers skills, `deep-research`, `claude-api` and
    `update-config`.
  - Deny every spelling of `rm -rf` (`-rf -fr -Rf -fR`, `-r -f`, `-f -r`,
    `--recursive --force`, `--force --recursive`).
  - Deny force-push with the flag anywhere (`git push --force*`, `git push -f*`,
    `git push *--force*`, `git push *-f *`).
  - Deny `git reset --hard*` and `git clean -f*`, `-d*` and `--force*`.
- Hooks: witness adds four (below). The rest come from iTerm2's Claude Code integration
  (§2). Until both have run, the hooks in a copied `settings.json` error on every call:
  cc-status doesn't exist yet, and the witness hooks point at the old clone. That's
  expected. Leave `settings.json` alone; both installers rewrite their own hooks.

### witness: a dated history of how I think and work, from my AI sessions

Go, served to Claude Code over MCP. <https://github.com/IngTian/witness>

👤 **First**, if you want the history: with no Claude sessions running on the old Mac (the DB
is in WAL mode), copy its `~/.local/share/witness` or `~/.local/share/claude-witness` to
`~/.local/share/witness` here. Any witness command creates an empty archive, and that one wins
over a copy made later. If it's already too late: `witness export --all <dir>` on the old Mac,
then `witness merge <dir>` here.

```sh
command -v go >/dev/null || brew install --formula go     # §3 has it too; witness needs it now
git clone https://github.com/IngTian/witness ~/devpro/ing/witness &&
  cd ~/devpro/ing/witness && ./install.sh claude
```

- Needs `go` 1.25+, `claude` on PATH, and about 450 MB for the embedding model, downloaded
  from Hugging Face.
- **The clone is the install.** The hooks and the MCP entry point into it by absolute path,
  so don't move it. To update: `git pull && ./install.sh claude`.
- `install.sh` builds the binary, fetches the model, merges four hooks into
  `~/.claude/settings.json` (replacing the old Mac's witness hooks in a copied file), and
  registers the MCP server `witness` at user scope. If `claude` isn't on PATH, that
  registration fails with only a warning, so check that `claude mcp list` shows `witness`.
- Run without a TTY (by Claude, say), it silently skips creating the `witness` command. Add it:
  `printf '#!/usr/bin/env bash\nexec "%s/hooks/witness.sh" "$@"\n' ~/devpro/ing/witness > ~/.local/bin/witness && chmod +x ~/.local/bin/witness`
- Don't also install it as a Claude Code plugin. That adds a second set of hooks.
- Check: `witness doctor`.

### ollama

`brew install --formula ollama && brew services start ollama`. The runner (~45 MB) starts at
login. Pull models deliberately, since they're 0.3–3 GB each. The one I use is
`nomic-embed-text` (274 MB).

## 2. Terminal & shell

### iTerm2

`brew install --cask iterm2`. The bundle is `iTerm.app`. Mine is close to stock: one
`Default` profile, no scripts, no dynamic profiles and no shell integration. So 👤 set these
by hand rather than copying the plist, which is mostly window frames and per-machine state:

- **iTerm2 → Install Claude Code Integration.** It creates `~/.config/iterm2/cc-status` (a
  link into `iTerm.app`), its Claude Code hooks, the profile's two Workgroup triggers and
  the Claude Code workgroup (Chat, Diff, Code Review). Don't write any of those by hand.
- **Settings → General → Magic → Enable Python API.** cc-status reports through `it2`,
  which refuses to run without it.
- **Profile `Default`:** font MesloLGS NF 18 (see `powerlevel10k` below); Window →
  Transparency 20, Blur 10.
- **Appearance → Theme: Dark.** **General → Selection → Applications in terminal may access
  clipboard**, so OSC 52 copies from tmux and ssh reach macOS.

```sh
brew install --formula powerlevel10k zsh-autosuggestions zsh-completions fzf autojump \
  ripgrep tmux htop
```

| | why |
|---|---|
| `powerlevel10k` | the prompt. 👤 Copy `~/.p10k.zsh` (~90 KB of wizard answers) plus `~/Library/Fonts/MesloLGS NF *.ttf`. Or re-run `p10k configure` inside iTerm2, which also installs the font. My answers: Nerd Font v3, lean, unicode, 24h, 2 lines, disconnected, no frame, compact, many icons, fluent, transient prompt, instant prompt verbose. Without the font, the icons show as boxes |
| `zsh-autosuggestions` `zsh-completions` | grey inline suggestions; extra completions |
| `fzf` | ⌃R history search that's actually usable |
| `autojump` | `j <partial-dir>` |
| `ripgrep` | search |
| `tmux` | long jobs survive a closed terminal |
| `htop` | `top` can't sort by RSS interactively |

### zsh

`~/.zshrc` is **one line, forever**:

```zsh
if [[ -r ~/.config/zsh/rc.zsh ]]; then source ~/.config/zsh/rc.zsh; fi
```

Every tool gets its own numbered file in `~/.config/zsh/conf.d/`, and the loader sources
them in filename order. The `.zshrc` this replaced was 242 lines, with `~/.local/bin` and
conda each prepended twice: seven installers had each appended a block, and nothing ever
removed one.

```zsh
# ~/.config/zsh/rc.zsh. `MACBOOT_ZSH_PROFILE=1 exec zsh` prints what each unit costs.
[[ -n $_rc_sourced ]] && return
_rc_sourced=1
[[ -n $MACBOOT_ZSH_PROFILE ]] && zmodload zsh/datetime
for _f in ~/.config/zsh/conf.d/*.zsh(N); do
  if [[ -n $MACBOOT_ZSH_PROFILE ]]; then
    _t=$EPOCHREALTIME; source $_f
    printf '%7.1f ms  %s\n' $(( (EPOCHREALTIME - _t) * 1000 )) ${_f:t} >&2
  else
    source $_f
  fi
done
unset _f _t
true
```

The loop is top-level, not in a function: inside a function, `typeset -U path` would be
undone on return.

**The one ordering rule.** Units below 50 may add to `$fpath`. `50-compinit` runs
`compinit`, once. Units above 50 may rely on completions. A vendor completion snippet
numbered under 50 runs its own compinit: gcloud's cost 297 ms at `20-` and almost nothing at
`60-`. Always use two digits; the sort is lexical.

| unit | contents |
|---|---|
| `00-path` | `HOMEBREW_PREFIX=/opt/homebrew` as a literal (no `brew shellenv` fork per shell); `typeset -U path fpath`; `path=(~/.local/bin(N-/) $HOMEBREW_PREFIX/bin(N-/) $HOMEBREW_PREFIX/sbin(N-/) $path ~/go/bin(N-/) ~/.cargo/bin(N-/))`: uv and node first, go and cargo last so project toolchains win |
| `05-p10k-instant` | source p10k's instant-prompt cache if it's readable. Must run before anything prints. Skipped while profiling |
| `10-history` | 200 000 / 200 000; `EXTENDED_HISTORY SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE HIST_REDUCE_BLANKS HIST_VERIFY HIST_FCNTL_LOCK` |
| `20-options` | `INTERACTIVE_COMMENTS NO_BEEP NO_FLOW_CONTROL`, and nothing else |
| `30-fpath` | brew's `share/zsh-completions` and `share/zsh/site-functions` |
| `45-nvm` | lazy: an `nvm` function that sources `nvm.sh` and its completion the first time it's called. `MACBOOT_NVM_EAGER=1` loads it up front, for an `.nvmrc` chpwd hook |
| `50-compinit` | the only `compinit`. `-i`, so it never shows the insecure-directories prompt. A full audit when `~/.zcompdump` is more than 24 h old, otherwise `-C`. Menu select, case-insensitive matching, completion cache |
| `60-keys` | `bindkey -e` explicitly (zsh switches to vi mode if `$EDITOR` contains "vi"). ↑/↓ search history by prefix, including `^[OA`/`^[OB` for tmux. ⌃←/⌃→ move by word; Home and End work; fn-⌫ deletes forward instead of typing `~`; ⌥⌫ deletes a word |
| `70-aliases` | guarded by `(($+commands[x]))` wherever they name an optional tool: eza `ls/ll/la/lt` (otherwise BSD `ls -G`, `ll`, `la`), `bcat` (bat), `rgh` (rg), `fda` (fd), `jqc` (jq). Unguarded: `g gs gd gds gl`, `.. ... ....`, `mkcd`, `path`/`fpath` (one entry per line), `df -h`, `du -h`, `ports` (`lsof -nP -iTCP -sTCP:LISTEN`), `localip`, `reload='exec zsh -l'`, `zprofile` |
| `80-plugins` | autosuggestions (strategy `history completion`, buffer max 80, both set before sourcing); fzf's shipped `completion.zsh` and `key-bindings.zsh`; autojump's `etc/profile.d/autojump.sh` (a function, because `alias j=autojump` can't `cd`) |
| `90-p10k` | brew's `share/powerlevel10k` theme, otherwise a `~/powerlevel10k` clone, then `~/.p10k.zsh` |

Copying beats rewriting. 👤 My current Mac keeps these units in `~/.config/macboot/conf.d/`
and my own aliases in `~/.config/zsh/conf.d/90-mine.zsh`. On the new Mac, both go into
`~/.config/zsh/conf.d/`. Leave behind its `60-gcloud.zsh` (work), its `README.md` (it
describes the old two-directory merge), and the `~/powerlevel10k` clone (from January,
never pulled; brew's theme takes precedence). Every unit is also in history:
`git show f71dd6f:shell/conf.d/<unit>.zsh`.
Before opening a new terminal, run
`for f in ~/.config/zsh/rc.zsh ~/.config/zsh/conf.d/*.zsh; do zsh -n $f || echo BROKEN $f; done`.
A syntax error here breaks every new terminal, including the one you'd use to fix it.

Don't:

- set `MANPATH` (one entry replaces the PATH-derived list and breaks `man ls`) or
  `INFOPATH` yourself (macOS has no `info`; `brew shellenv` already exports it);
- call `compinit` outside unit 50, or `source ~/.zshrc` to reload (use `exec zsh -l`);
- alias `python`, `pip`, `grep`→`rg` or `cat`→`bat`.

## 3. Development

| app | cask | bundle | note |
|---|---|---|---|
| VS Code | `visual-studio-code` | `Visual Studio Code.app` | 👤 Settings Sync is a GitHub login |
| Docker Desktop | `docker-desktop` | `Docker.app` | 👤 sudo: it links `docker` into `/usr/local/bin`. Not `brew install docker` (CLI only). Watch the build cache; it once reached 76 GB |
| Google Chrome | `google-chrome` | `Google Chrome.app` | DevTools, and checking what Safari renders differently |

```sh
brew install --formula git-lfs go cmake ninja shellcheck shfmt pre-commit gnupg
git lfs install
```

| | why |
|---|---|
| `git-lfs` | large files; `git lfs install` adds its filter to `~/.gitconfig` |
| `go` | brew's go, no goenv. A go.mod `go` line newer than brew's makes go fetch that toolchain itself (see Languages) |
| `cmake` `ninja` | all of C/C++. Compilers come from the CLT. No vcpkg, no Conan |
| `shellcheck` `shfmt` `pre-commit` | writing shell |
| `gnupg` | for signing commits and tags (nothing turns that on yet) |

### git

`~/.config/git/config` holds the defaults I want everywhere:

```ini
[user]
	useConfigOnly = true                 # no identity means a hard stop, never a guessed one
[init]
	defaultBranch = main
[pull]
	rebase = true
[push]
	autoSetupRemote = true
[fetch]
	prune = true
[rerere]
	enabled = true
[core]
	excludesfile = ~/.config/git/ignore  # pinned: the XDG default moves if XDG_CONFIG_HOME does
[diff]
	colorMoved = zebra
```

`~/.config/git/ignore` holds:

- `**/.claude/settings.local.json`. The `**/` matters: a pattern containing a slash
  otherwise matches only at the repo root.
- Finder droppings: `.DS_Store`, `._*` and the rest.
- Editor files: `.idea/`, `*.iml`, `*.swp`, `*~`.
- Python: `.venv/`, `venv/`, `__pycache__/`, `*.py[cod]`, `.pytest_cache/`, `.mypy_cache/`,
  `.ruff_cache/`.
- `node_modules/` and `.direnv/`.

`.vscode/` is deliberately not on the list; if it were, a repo couldn't re-include its
`launch.json`.

👤 **Identity: ask me, never derive it.** The work identity goes in `~/.gitconfig`. Personal
repos get theirs by directory. Append this to `~/.gitconfig` after its `[user]` block, not to
`~/.config/git/config`, which git reads first, so the work identity would win:

```ini
[includeIf "gitdir:~/devpro/ing/"]       # the trailing slash is required
	path = ~/devpro/ing/.gitconfig
```

Check from inside a repo with `git config --includes --get user.email`. A missing include
file is ignored silently.

### Languages: one manager each, and a default toolchain

Two managers for one language is how a shell runs the wrong interpreter without telling you.
The rule for the rest: a project's tools are its own dependencies, pinned by its lockfile.
Only things I use outside projects are installed globally.

| | Python | Node / TS | Go | Rust | C/C++ |
|---|---|---|---|---|---|
| manager | uv | nvm | brew `go` | rustup | the CLT |
| default version | 3.13 | `lts/*` | brew's stable | `stable` | Apple clang |
| project pin | `requires-python`, `uv.lock` | `.nvmrc`, `package-lock.json` | go.mod `go` line, `go.sum` | `rust-toolchain.toml`, `Cargo.lock` | — |
| format | `ruff format` | VS Code built-in | `gofmt` | `cargo fmt` | `xcrun clang-format` |
| lint | `ruff check` | `tsc` strict | `go vet`, plus staticcheck, errcheck, deadcode | `cargo clippy` | clangd's clang-tidy |
| types | none (Pylance) | `typescript` per project | the compiler | the compiler | the compiler |
| test | `pytest` | `node --test`, or `vitest` where Vite is | `go test -race` | `cargo test` | `ctest` |
| VS Code | Python, Ruff | built-in | Go (fetches gopls, dlv) | rust-analyzer | clangd |
| global | `uv tool` apps | nothing | three linters in `~/go/bin` | rustfmt, clippy | `cmake`, `ninja` |

**Python is uv's.** No conda, pyenv, `pip install` or global venv.

```sh
curl -LsSf https://astral.sh/uv/install.sh | env INSTALLER_NO_MODIFY_PATH=1 sh &&   # → ~/.local/bin
  uv python install --default 3.13
```

- `--default` puts `python` and `python3` in `~/.local/bin`. Otherwise `/usr/bin/python3` is
  3.9.6, years behind, and brew's `python3` arrives uninvited as a dependency of
  pre-commit, autojump and ollama and wins. 3.13 is the newest version my CI tests. Older
  versions arrive on demand: `uv sync --python 3.11`.
- Per project: `uv add --dev ruff pytest` puts them in `[dependency-groups] dev`, which
  `uv sync` installs by default. A `[project.optional-dependencies] dev` extra isn't
  installed by default, so a plain `uv sync` leaves pytest out. Then
  `uv run ruff format`, `uv run ruff check .` and `uv run pytest -q`. Commit `uv.lock`.
- Global only for apps: `uv tool install` (kaggle, trading-desk, daylogs). A one-off is
  `uvx <tool>`. Never `uv tool install` ruff or pytest, because CI runs the locked versions.
- Loose scripts: `uv add --script fig.py matplotlib numpy` writes the deps into the file,
  then `uv run fig.py`. Notebooks, when there is one: `uv run --with jupyter jupyter lab`.
- VS Code: the Python extension (Pylance, debugger) and Ruff (`charliermarsh.ruff`). Set
  `"[python]": {"editor.defaultFormatter": "charliermarsh.ruff"}` so format-on-save matches
  CI. Ruff runs the project's own `.venv` ruff first.

**Node is nvm's**, for several versions side by side.

```sh
v=$(gh api repos/nvm-sh/nvm/releases/latest -q .tag_name) &&    # a tag, never master
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$v/install.sh" | PROFILE=/dev/null bash &&
  . ~/.nvm/nvm.sh && nvm install --lts && nvm alias default 'lts/*' &&
  n=$(nvm which default) && for b in node npm npx; do ln -sf "${n%/node}/$b" ~/.local/bin/$b; done
```

- Default to `lts/*`, not a number. A default pinned to `20` stayed on 20 after 24 was
  installed.
- The links let `nvm.sh` load lazily: loaded eagerly it cost 943 ms, 71% of shell startup.
  They also let hooks and cron, which never read `.zshrc`, find node. Re-run the last line
  after each LTS bump, in a shell where `nvm` is loaded. If `nvm` isn't loaded, `nvm which`
  prints nothing and the links point at themselves.
- Check in a clean environment, not in your own shell (that one already has nvm loaded):
  `env -i HOME=$HOME /bin/zsh -c 'command -v node npm npx'`
- **npm, the package manager that ships with node.** Every repo has a `package-lock.json`,
  and CI runs `npm ci`. No pnpm, yarn or bun, and no corepack: Node 25 stopped shipping it.
- A project pins its node in `.nvmrc`, which CI reads too (`node-version-file: .nvmrc`).
  `nvm install` inside the repo fetches that version.
- Nothing global. Tools are devDependencies, run with `npx`; a one-off is just
  `npx <tool>`. A `npm i -g` bin lands in the nvm version's `bin/`, which a new terminal
  can't see until `nvm` loads, and which the next LTS leaves behind.
- Types: `npm i -D typescript`, then `npx tsc --noEmit`. Outside a project, `npx tsc` fetches
  an ancient TypeScript 2.0. For Astro, `astro check`, because `astro build` doesn't
  type-check.
- Tests: `node --test` with `node:assert/strict`, and `vitest` only where Vite already is.
  Run `.ts` scripts with `node x.ts` (types are stripped by default since 22.18; no enums,
  no `.tsx`), not tsx or ts-node.
- Editor: VS Code's built-in TS server, formatter and debugger. No prettier and no linter
  until a repo has a second contributor.

**Go is brew's `go`**, with `GOTOOLCHAIN` left at `auto`. If a go.mod `go` line is newer than
brew's go, that toolchain is downloaded for that module, so the version lives in go.mod. CI
reads the same line (`go-version-file: go.mod`).

```sh
for p in honnef.co/go/tools/cmd/staticcheck github.com/kisielk/errcheck golang.org/x/tools/cmd/deadcode; do
  go install $p@latest
done
```

- Built in: `gofmt`, `go vet`, `go test -race` (works with `CGO_ENABLED=0` on macOS) and
  modules (commit `go.sum`). Each repo wires them into `make fmt vet test`.
- The three linters live in `~/go/bin` because I run them by hand across repos rather than
  as gates. Re-run the loop when brew moves go to a new minor version: a linter built with
  go1.N refuses a `go 1.N+1` module.
- Vulnerabilities, when needed, with no install:
  `go run golang.org/x/vuln/cmd/govulncheck@latest ./...`
- VS Code: the Go extension (`golang.go`) installs `gopls`, and `dlv` the first time you
  debug, into `~/go/bin` itself. Don't pre-install them.
- Not used: golangci-lint (it wraps the same checks), gofumpt, goimports (gopls organizes
  imports), and go.mod `tool` lines (tool deps join the module's version selection).

**Rust is rustup's**, never `brew install rust`; the two fight over `~/.cargo/bin`. I don't
use it yet, so install it with the first Rust project:

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs |
  sh -s -- -y --no-modify-path --profile minimal -c rustfmt,clippy
```

- Stay on `stable` and update by hand with `rustup update`. A project that needs a version
  pins it in `rust-toolchain.toml` with `components = ["rustfmt", "clippy"]`, and rustup
  installs that toolchain on first use.
- The minimal profile plus rustfmt and clippy is the default profile without `rust-docs`,
  which is 718 MB of a 1.2 GB toolchain. §2 puts `~/.cargo/bin` on PATH.
- `cargo fmt`, `cargo clippy` and `cargo test`; `rust-lldb` on top of the CLT's lldb.
- VS Code: `rust-lang.rust-analyzer` bundles its own server, so no rust-analyzer component.

**C/C++ uses the CLT as the toolchain** (clang, lldb, clangd, clang-format), plus brew's
`cmake` and `ninja`. No brew `llvm`, no vcpkg, no Conan; dependencies come per project
through CMake `FetchContent`.

- `cmake -B build -G Ninja -DCMAKE_EXPORT_COMPILE_COMMANDS=ON`. clangd reads that
  database, and `ctest` comes with cmake.
- Run `xcrun clang-format`, since there's no `/usr/bin` shim. clang-tidy only ships with
  brew's llvm; clangd's built-in clang-tidy covers the editor.
- VS Code: `llvm-vs-code-extensions.vscode-clangd`, which uses `/usr/bin/clangd`.

**Swift**: the CLT's `swiftc`, which is what manifold builds with. Nothing else.

VS Code extensions come over with 👤 Settings Sync. To add one on the command line, use
`"/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" --install-extension <id>`,
since `code` isn't on PATH until you run Shell Command: Install 'code' command in PATH.

## 4. Markets & research

| app | cask | bundle | note |
|---|---|---|---|
| TradingView | `tradingview` | `TradingView.app` | 👤 sign in |

```sh
brew install --formula tectonic poppler ghostscript
uv tool install kaggle     # 👤 then put the API token from kaggle.com → Settings into ~/.kaggle/
```

| | why |
|---|---|
| `tectonic` | LaTeX for a paper, without 5 GB of MacTeX |
| `poppler` | `pdftotext`, `pdfimages` |
| `ghostscript` | PDF and PostScript conversion |
| `kaggle` | datasets and competitions from the terminal |

### trading-desk: a trading book in the terminal

Python. A SQLite book, a Textual TUI, and a checker that won't let the record contradict
itself. <https://github.com/IngTian/trading-desk>

```sh
uv tool install trading-desk     # → desk, desk-migrate, desk-check
```

- The book is `~/Documents/trading-desk/hub.db`. I keep it there, inside iCloud Desktop &
  Documents sync, so it arrives with the rest of `~/Documents`, and I open it from one Mac
  at a time. The tool's README prefers an unsynced folder (set `TRADING_DESK_HOME`), and
  copies off the machine as snapshots: `sqlite3 hub.db "VACUUM INTO '<dest>.db'"`.
- On a new Mac, run `desk-migrate --check` before the first `desk`. If `hub.db` hasn't
  arrived from iCloud yet, skip the check and leave it on my list. My current Mac runs
  `desk` from a dev checkout, so make sure PyPI's schema isn't behind the book's. The
  check says so.
- Check: `desk --version`.

## 5. Notes, tasks & life

| app | cask | bundle | note |
|---|---|---|---|
| Obsidian | `obsidian` | `Obsidian.app` | my vaults are git repos I clone myself; each carries its own `.obsidian/` |
| TickTick | `ticktick` | `TickTick.app` | from the App Store on my current Mac; the cask works too. 👤 sign in |
| Google Drive | `google-drive` | `Google Drive.app` | 👤 sudo (a `.pkg`). Also installs the Docs, Sheets and Slides apps |

### daylogs: weight, food and spending in the terminal, typed by hand

Python. <https://github.com/IngTian/daylogs>

```sh
uv tool install daylogs && mkdir -p ~/Documents/daylogs/inbox     # → day
```

- Data lives in `~/Documents/daylogs/`: the DB, `config.toml`, `memory.md`, and `inbox/` for
  phone photos (daylogs never creates it). It expects iCloud **Desktop & Documents** sync;
  that's how the phone photos and the DB reach the Mac.
- Keep every Mac that shares the DB on the same version: an older one can move the schema
  stamp backwards. Install the latest here, then 👤 run `uv tool upgrade daylogs` on the
  old Mac before it opens the DB again.
- Estimates and the daily read call `claude -p`. Everything else works without it.
- Check: `day --version`.

## 6. Mac utilities

| app | cask | bundle | note |
|---|---|---|---|
| Raycast | `raycast` | `Raycast.app` | 👤 the ⌘-Space swap, §8 |
| Snipaste | `snipaste` | `Snipaste.app` | screenshots: snip, annotate, pin to screen |
| AirStats | `airstats` | `AirStats.app` | menu-bar system monitor |

`brew install --formula ffmpeg` for audio and video from the terminal.

### manifold: a mountain as breathing points of light

A macOS screensaver and live wallpaper in Swift, built with the CLT's `swiftc` (no Xcode).
<https://github.com/IngTian/manifold>

```sh
curl -fsSL https://raw.githubusercontent.com/IngTian/manifold/main/scripts/install.sh | bash -s -- all
```

- `all` installs the screensaver (`~/Library/Screen Savers/Manifold.saver`) and the
  wallpaper (`/Applications/Manifold Wallpaper.app`). With no argument, only the screensaver.
- 👤 Pick it in System Settings → Screen Saver → Other → Manifold. For the wallpaper, use
  the ⛰ menu-bar icon → Launch at login. If that toggle fails, add the app under Login Items.
- To update, re-run the same line.

## 7. Chat, calls & remote

| app | cask | bundle | note |
|---|---|---|---|
| WeChat | `wechat` | `WeChat.app` | from the App Store on my current Mac; the cask works too |
| Discord | `discord` | `Discord.app` | |
| Windows App | `windows-app` | `Windows App.app` | 👤 sudo (a `.pkg`). RDP to my Windows desktop. When it only says "failed", `brew install --formula freerdp` and `xfreerdp /v:<host> +auth-only` show whether it's the credentials |

Slack and Zoom are on my current Mac for work only, so they aren't listed.

## 8. By hand 👤, and why

| step | why it isn't automated |
|---|---|
| Xcode CLT dialog | GUI-only, and accepting a licence for someone isn't OK |
| Homebrew's sudo password, and the `.pkg` casks' | needs a TTY |
| `gh auth login`, `claude` login, app sign-ins | browser plus a one-time code |
| git identity | only I know which email goes where |
| iTerm2: the Claude Code integration, Enable Python API, profile font, transparency, theme | iTerm2 owns the `cc-status` link, its hooks, triggers and workgroup. The rest is a handful of clicks; the plist is mostly per-machine state |
| `p10k configure`, or copy `~/.p10k.zsh` across | ~90 KB of wizard answers |
| Raycast on ⌘-Space: set Raycast's hotkey to ⌘-Space **first**, then System Settings → Keyboard → Keyboard Shortcuts → Spotlight → untick it | in that order the key is never dead. Scripting it means splicing `symbolichotkeys` and logging out |
| choosing the screensaver | WallpaperAgent owns and rewrites the selection store |
| App Store, licences, 2FA | secrets and second devices (so no `mas`) |
| a second copy of the SSH key, off this laptop, tested once | nothing can do key custody for you, and an untested backup is a belief |
| Time Machine destination | enrolling a disk can erase it |
| Full Disk Access for iTerm, if wanted | TCC is SIP-protected |
| `chsh -s /bin/zsh`, only if `dscl . -read ~ UserShell` isn't zsh already | PAM password prompt |
| iCloud sign-in with Desktop & Documents on, before anything writes to `~/Documents` (§0) | Apple ID 2FA. Turned on late, it splits `~/Documents` instead of merging it |
| `uv tool upgrade daylogs` on the old Mac (§5) | another machine |
| data from the old Mac: `~/.ssh` and `~/.claude/` (§0), witness history (§1, *before* installing), zsh units (§2), `~/.p10k.zsh` and the MesloLGS NF fonts, `~/.kaggle/`, `~/devpro/adversarial-audit-plugin`, and `~/.zsh_history` if I want it | not mine to sync blindly. daylogs and trading-desk arrive through iCloud |

## Not installed, on purpose

- **brew `git` and `jq`.** Apple ships both: `git` with the CLT, and `/usr/bin/jq`. A
  second copy that shadows a working one isn't worth a minor version.
- **brew `python`, pyenv, conda, brew `node`, brew `rust`, goenv, vcpkg, Conan.** One
  manager per language (§3).
- **brew `zsh`.** `/bin/zsh` is already the default, and brew's would need a root edit to
  `/etc/shells`.
- **MacTeX** (tectonic covers it) and **ollama models** (pulled by choice).
- **`defaults write` preferences.** They're taste, so I set them by hand.
- **Nix, Ansible, chezmoi.** This runs before any package manager exists.
- **iTerm2 shell integration.** Not on my current Mac, and its installer appends to
  `~/.zshrc`. If I ever want it, it goes in a §2 unit.
- **iTerm2's own AI assistant.** In iTerm2 I only use Claude Code. My old Mac's prefs point
  the assistant at OpenAI, and none of that carries over, which is what I want.
- **`p7zip`, `mkcert`, `gifsicle`.** They were on my current Mac, but I never used them.
- **Work-only tools on my current Mac:** Slack, Zoom, gcloud, glab, gitlab-runner, buf,
  protobuf, kubeconform, lua and redis. Also left out: one-offs (`wimlib`, `mcp-publisher`,
  which witness's CI now runs) and autotools, which a build pulls in when it needs them.
- **Not on my current Mac, so not here:** `fd`, `bat`, `eza`, `tree`, `yq`, `direnv` and
  `zoxide`. The aliases in `70-aliases` light up if any of them gets installed. Don't wire
  zoxide next to autojump: they fight over `j`.
- **MDM removal.** If the Mac is managed, warn and continue; Jamf reinstalls the agent anyway.
