# macboot

What I install on a new Mac, and how I want it set up. One file, no scripts: do it by
hand, top to bottom, or do §0 by hand and give the rest to Claude Code:

```sh
gh repo clone IngTian/macboot ~/devpro/ing/macboot && cd ~/devpro/ing/macboot && claude
```

> Set up this Mac from README.md. Look before you change anything: skip whatever is already
> installed or solved differently, and never upgrade what's there. Stop and hand me every 👤
> step. Finish with three lists: done, skipped (and why), left for me.

**Why there's no script.** This repo used to be ~4,700 lines of idempotent bash. Nearly
every bug it ever had was the same shape: a fixed plan run against a machine it hadn't
looked at (`brew shellenv` already in `.zprofile`, nvm already sourced). An agent looks
first. The decisions were always the valuable part. The scripted version is still in
history at `f71dd6f`.

## Rules for whoever runs this

- **Apple Silicon, current macOS.** `uname -m` must print `arm64` and
  `sysctl -n sysctl.proc_translated` must print `0`. A terminal running under Rosetta
  installs x86_64 everything without a warning. `/opt/homebrew` is assumed throughout.
- **Look, then act.** Check before every install and skip what exists. Never upgrade
  something as a side effect.
- **Nothing gets appended to `~/.zshrc`, `~/.zprofile` or `~/.zshenv` unchecked.** `grep`
  first. Keep vendor installers out of rc files (`INSTALLER_NO_MODIFY_PATH=1`,
  `PROFILE=/dev/null`, `--no-modify-path`). After installing apps, grep the rc files again:
  Docker Desktop and others append their own lines. Fold those into a §5 unit.
- **👤 means a person.** Passwords, browser logins, GUI dialogs, System Settings, which
  email goes where. Don't guess them and don't script around them.
- **No secrets in this repo.** Keys, tokens, licences and private config move from the old
  Mac by hand.

## 0. Bootstrap 👤

Each of these needs a person, in this order:

```sh
xcode-select --install     # 👤 dialog: Install, Agree. clang, git, the SDK
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"  # 👤 sudo password
grep -q 'brew.*shellenv' ~/.zprofile 2>/dev/null ||
  echo 'if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
brew install gh && gh auth login --git-protocol ssh    # 👤 browser; also creates + uploads an SSH key
curl -fsSL https://claude.ai/install.sh | bash          # Claude Code, native: auto-updates
claude                                                   # 👤 browser login
```

- Don't set `NONINTERACTIVE=1` for Homebrew. It switches to `sudo -n` and aborts on a fresh
  admin account.
- `shellenv` goes in `~/.zprofile`, not `.zshrc`. Login shells, hooks and LaunchAgents
  read `.zprofile`; `.zshrc` is only read by interactive shells.
- After a major macOS upgrade, `test -d "$(xcode-select -p)"`. The CLT receipt survives
  the upgrade; the directory sometimes doesn't, and the next `brew install` dies looking for
  clang.

## 1. Command-line tools

```sh
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1
brew install --formula gh powerlevel10k zsh-autosuggestions zsh-completions fzf autojump \
  ripgrep tmux htop gnupg go cmake ninja shellcheck shfmt pre-commit ollama
```

Not `brew bundle`: it treats *outdated* as *missing* and upgrades it. `--formula` stops a
name from resolving to a cask.

| | why |
|---|---|
| `gh` | GitHub sign-in and SSH key upload in one step |
| `powerlevel10k` `zsh-autosuggestions` `zsh-completions` `fzf` `autojump` | the shell, §5 |
| `ripgrep` | search |
| `tmux` | long jobs survive a closed terminal |
| `htop` | `top` can't sort by RSS interactively |
| `gnupg` | for signing commits and tags (nothing turns that on yet) |
| `go` | brew's go, no goenv. Since 1.21 a `go.mod` `toolchain` line fetches the version a project needs |
| `cmake` `ninja` | all of C/C++. Compilers come from the CLT. No vcpkg, no Conan |
| `shellcheck` `shfmt` `pre-commit` | writing shell |
| `ollama` | the runner only (~30 MB). Pull models deliberately, 0.3–3 GB each |

When the need shows up:

| | |
|---|---|
| `fd` | `find` that respects `.gitignore` |
| `bat` | highlighted `cat`, as `bcat`. Never aliased over `cat` |
| `eza` | `ls` with git columns, aliased only when installed |
| `tree` | a directory's shape on one screen |
| `yq` | `jq` for YAML |
| `direnv` | per-directory env. Needs a shell hook, so it's opt-in |
| `zoxide` | installed, **not** wired: it fights autojump over `j`. Pick one |
| `tectonic` | LaTeX for a paper without 5 GB of MacTeX |
| `redis` | for experiments, never started as a service |
| `mkcert` | locally-trusted TLS certs |
| `p7zip` | archives Archive Utility won't open |
| `poppler` | `pdftotext`, `pdfimages` |
| `gifsicle` | screen-recording GIFs down to attachable |

## 2. Languages: one manager each

Two managers for one language is how a shell runs the wrong interpreter without telling you.

**Python is uv's.** No conda, pyenv, `pip install` or global venv.

```sh
curl -LsSf https://astral.sh/uv/install.sh | env INSTALLER_NO_MODIFY_PATH=1 sh   # → ~/.local/bin
uv python install --default 3.13
```

`--default` puts `python` and `python3` in `~/.local/bin`, which is first on PATH. Without
it, `/usr/bin/python3` is 3.9 with no pip, and brew's `python@3.14` arrives uninvited as a
dependency of pre-commit, ollama and autojump and wins `python3`. Per project, run `uv sync`
and commit `uv.lock`.

**Node is nvm's**, for several versions side by side.

```sh
v=$(gh api repos/nvm-sh/nvm/releases/latest -q .tag_name)     # a tag, never master
curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$v/install.sh" | PROFILE=/dev/null bash
. ~/.nvm/nvm.sh && nvm install --lts && nvm alias default 'lts/*'
for b in node npm npx; do ln -sf "$(dirname "$(nvm which default)")/$b" ~/.local/bin/$b; done
```

- Default to `lts/*`, not a number. A default pinned to `20` stayed on 20 after 24 was
  installed.
- The symlinks let `nvm.sh` load lazily: loaded eagerly it cost 943 ms, 71% of shell
  startup. They also let hooks, LaunchAgents and cron, which never read `.zshrc`, find node.
  Re-run the loop after each LTS bump.
- `~/.zshenv` is the one file every zsh reads. It puts `~/.local/bin` on PATH, guarded:
  `case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac`
- Check in a clean environment, not in your own shell (that one already has nvm loaded):
  `env -i HOME=$HOME /bin/zsh -c 'command -v node npm npx'`

**Go**: brew `go` (§1). `~/go/bin` goes at the end of PATH so a project's toolchain wins.

**Rust**: rustup, and only when needed. Never `brew install rust`; the two fight over
`~/.cargo/bin`. `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path`.
§5 already puts `~/.cargo/bin` on PATH.

**C/C++**: CLT compilers, `cmake`, `ninja`.

## 3. Apps

Install one cask at a time, and only if the app isn't already in `/Applications`: a cask
over an app dragged in from a `.dmg` fails. No casks in any bundle file.

| app | `brew install --cask …` | note |
|---|---|---|
| VS Code | `visual-studio-code` | 👤 Settings Sync is a GitHub login |
| iTerm2 | `iterm2` | the bundle is `iTerm.app`. Ships `cc-status`, which the Claude Code hooks call |
| Obsidian | `obsidian` | §4 |
| Raycast | `raycast` | 👤 the ⌘-Space swap, §8 |
| Google Chrome | `google-chrome` | DevTools, and checking what Safari renders differently |
| Docker Desktop | `docker-desktop` | not `brew install docker`, which is CLI-only. Appends to `~/.zprofile`. Watch the build cache (it once reached 76 GB) |

Claude Code isn't a cask here on purpose. The cask doesn't auto-update; the native
installer (§0) does.

## 4. My tools

Clones live under `~/devpro/ing/`. Each repo's README is the authority; this is the short
form.

### witness: a dated history of how I think and work, from my AI sessions

Go, served to Claude Code over MCP. <https://github.com/IngTian/witness>

```sh
git clone https://github.com/IngTian/witness ~/devpro/ing/witness
cd ~/devpro/ing/witness && ./install.sh claude
```

- Needs `go` 1.25+, `claude` on PATH, and about 450 MB for the embedding model, downloaded
  from Hugging Face.
- **The clone is the install.** The hooks and the MCP entry point into it by absolute path,
  so don't move it. To update: `git pull && ./install.sh claude`.
- `install.sh` builds the binary, fetches the model, merges four hooks into
  `~/.claude/settings.json`, and registers the MCP server `witness` at user scope. If
  `claude` isn't on PATH, that registration fails with only a warning, so check that
  `claude mcp list` shows `witness`.
- Run without a TTY (by Claude, say), it silently skips creating the `witness` command.
  Add it from the clone:
  `printf '#!/usr/bin/env bash\nexec "%s/hooks/witness.sh" "$@"\n' "$PWD" > ~/.local/bin/witness && chmod +x ~/.local/bin/witness`
- Don't also install it as a Claude Code plugin. That adds a second set of hooks.
- 👤 History lives in `~/.local/share/witness` (older installs: `~/.local/share/claude-witness`).
  To keep it, copy that folder from the old Mac. witness has `export` but no import.
- Check: `witness doctor`.

### daylogs: weight, food and spending in the terminal, typed by hand

Python. <https://github.com/IngTian/daylogs>

```sh
uv tool install daylogs          # → day
```

- Data lives in `~/Documents/daylogs/`: the DB, `config.toml`, `memory.md`, and an
  `inbox/` for phone photos. It expects iCloud **Desktop & Documents** sync; that's how the
  phone photos and the DB reach the Mac.
- Keep every Mac on the same version. An older version can move the shared DB's schema
  stamp backwards.
- Estimates and the daily read call `claude -p`. Everything else works without it.
- Check: `day --version`.

### trading-desk: a trading book in the terminal

Python. A SQLite book, a Textual TUI, and a checker that won't let the record contradict
itself. <https://github.com/IngTian/trading-desk>

```sh
uv tool install trading-desk     # → desk, desk-migrate, desk-check
```

- The book is `~/Documents/trading-desk/hub.db`. Its README wants the live book **out of**
  sync folders (one writer at a time). With Desktop & Documents sync on, set
  `TRADING_DESK_HOME` to an unsynced folder. Copies off the machine are snapshots:
  `sqlite3 hub.db "VACUUM INTO '<dest>.db'"`.
- 👤 Moving Macs: copy `hub.db` (and `config.toml`) across, then run `desk-migrate --check`.
- Check: `desk --version`.

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

### Obsidian

`brew install --cask obsidian`. My vaults are git repos that I clone myself, and each one
carries its own `.obsidian/`. Nothing to configure here.

## 5. Shell (zsh)

`~/.zshrc` is **one line, forever**:

```zsh
if [[ -r ~/.config/zsh/rc.zsh ]]; then source ~/.config/zsh/rc.zsh; fi
```

Every tool gets its own numbered file in `~/.config/zsh/conf.d/`, and the loader sources
them in filename order. The `.zshrc` this replaced was 242 lines, with `~/.local/bin` and
conda each prepended twice: seven installers had each appended a block, and nothing ever
removed one.

```zsh
# ~/.config/zsh/rc.zsh. `ZSH_PROFILE=1 exec zsh` prints what each unit costs.
[[ -n $_rc_sourced ]] && return
_rc_sourced=1
[[ -n $ZSH_PROFILE ]] && zmodload zsh/datetime
for _f in ~/.config/zsh/conf.d/*.zsh(N); do
  if [[ -n $ZSH_PROFILE ]]; then
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
| `45-nvm` | lazy: an `nvm` function that sources `nvm.sh` the first time it's called |
| `50-compinit` | the only `compinit`. `-i`, so it never shows the insecure-directories prompt. A full audit when `~/.zcompdump` is more than 24 h old, otherwise `-C`. Menu select, case-insensitive matching, completion cache |
| `60-keys` | `bindkey -e` explicitly (zsh switches to vi mode if `$EDITOR` contains "vi"). ↑/↓ search history by prefix, including `^[OA`/`^[OB` for tmux. ⌃←/⌃→ move by word |
| `70-aliases` | each one guarded by `(($+commands[x]))`: eza `ls/ll/la/lt`; `bcat`; `g gs gd gds gl`; `mkcd`; `ports` (`lsof -nP -iTCP -sTCP:LISTEN`); `rgh`; `fda`; `reload='exec zsh -l'` |
| `80-plugins` | autosuggestions (strategy `history completion`, buffer max 80, both set before sourcing); fzf's shipped `completion.zsh` and `key-bindings.zsh`; autojump's `etc/profile.d/autojump.sh` (a function, because `alias j=autojump` can't `cd`) |
| `90-p10k` | the powerlevel10k theme, then `~/.p10k.zsh` |

Every unit, verbatim: `git show f71dd6f:shell/conf.d/<unit>.zsh`. Before opening a new
terminal, run `for f in ~/.config/zsh/rc.zsh ~/.config/zsh/conf.d/*.zsh; do zsh -n $f || echo BROKEN $f; done`.
A syntax error here breaks every new terminal, including the one you'd use to fix it.

Don't:

- set `MANPATH` (one entry replaces the PATH-derived list and breaks `man ls`) or
  `INFOPATH` (macOS has no `info`, and the variable grows on every `exec zsh`);
- call `compinit` outside unit 50, or `source ~/.zshrc` to reload (use `exec zsh -l`);
- alias `python`, `pip`, `grep`→`rg` or `cat`→`bat`;
- wire up both zoxide and autojump.

## 6. Git

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

👤 **Identity: ask me, never derive it.** The work identity goes in `~/.gitconfig`.
Personal repos get theirs by directory:

```ini
[includeIf "gitdir:~/devpro/ing/"]       # trailing slash required; must come after [user]
	path = ~/devpro/ing/.gitconfig
```

Check from inside a repo with `git config --includes --get user.email`. A missing include
file is ignored silently.

## 7. Claude Code

It's installed in §0. Then:

```sh
claude plugin marketplace add anthropics/claude-plugins-official
claude plugin install superpowers@claude-plugins-official
claude plugin install frontend-design@claude-plugins-official
claude plugin marketplace add DietrichGebert/ponytail
claude plugin install ponytail@ponytail
```

- 👤 `adversarial-audit` is a local plugin with no remote. Copy its directory from the old
  Mac, then run `claude plugin marketplace add <dir>`.
- **Copy `~/.claude/settings.json`, never symlink it.** Claude Code rewrites the file
  itself (plugin registrations, key order). 👤 Bring over the old Mac's. If starting from
  scratch, it looks like this:
  - `effortLevel: xhigh` and `alwaysThinkingEnabled`.
  - Allow `Bash`, `Read`, `Edit`, `Write` and `WebFetch`.
  - Deny every spelling of `rm -rf` (`-rf -fr -Rf -fR`, `-r -f`, `-f -r`,
    `--recursive --force`, `--force --recursive`).
  - Deny force-push with the flag anywhere (`git push --force*`, `git push -f*`,
    `git push *--force*`, `git push *-f *`).
  - Deny `git reset --hard*` and `git clean -f*`, `-d*` and `--force*`.
- Hooks: witness's `install.sh` adds its own. The rest call iTerm2's
  `~/.config/iterm2/cc-status`, a symlink into `iTerm.app`.
- 👤 Private, and never in this repo: `~/.claude/CLAUDE.md`, `~/.claude/memory/`, and the
  per-project memory under `~/.claude/projects/`. Copy them across by hand.

## 8. By hand 👤, and why

| step | why it isn't automated |
|---|---|
| Xcode CLT dialog | GUI-only, and accepting a licence for someone isn't OK |
| Homebrew sudo password | needs a TTY |
| `gh auth login`, `claude` login | browser plus a one-time code |
| git identity | only I know which email goes where |
| `p10k configure`, or copy `~/.p10k.zsh` across | ~90 KB of wizard answers |
| Raycast on ⌘-Space: set Raycast's hotkey to ⌘-Space **first**, then System Settings → Keyboard → Keyboard Shortcuts → Spotlight → untick it | in that order the key is never dead. Scripting it means splicing `symbolichotkeys` and logging out |
| choosing the screensaver | WallpaperAgent owns and rewrites the selection store |
| App Store, licences, 2FA | secrets and second devices (so no `mas`) |
| a second copy of the SSH key, off this laptop, tested once | nothing can do key custody for you, and an untested backup is a belief |
| Time Machine destination | enrolling a disk can erase it |
| Full Disk Access for iTerm, if wanted | TCC is SIP-protected |
| `chsh -s /bin/zsh`, only if `dscl . -read ~ UserShell` isn't zsh already | PAM password prompt |
| data from the old Mac: `~/.local/share/witness`, `~/Documents/trading-desk/`, `~/.p10k.zsh`, `~/.ssh`, the private `~/.claude/` files | not mine to sync blindly. daylogs arrives through iCloud |

## Not installed, on purpose

- **brew `git` and `jq`.** Apple ships both: `git` with the CLT, and `/usr/bin/jq`. A
  second copy that shadows a working one isn't worth a minor version.
- **brew `python`, pyenv, conda, brew `node`, brew `rust`, goenv, vcpkg, Conan.** One
  manager per language (§2).
- **brew `zsh`.** `/bin/zsh` is already the default, and brew's would need a root edit to
  `/etc/shells`.
- **MacTeX** (tectonic covers it) and **ollama models** (pulled by choice).
- **`defaults write` preferences.** They're taste, so I set them by hand.
- **Nix, Ansible, chezmoi.** This runs before any package manager exists.
- **MDM removal.** If the Mac is managed, warn and continue; Jamf reinstalls the agent anyway.
