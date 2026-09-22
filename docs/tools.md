# Tools

What I install, and **why each one over the obvious alternative**. The second half is the
part worth reading; the list itself you could guess.

Everything here targets **Apple Silicon on current macOS**. Nothing is tested on Intel or on
older releases, and several choices below are only safe because of that.

`brew bundle --file Brewfile` installs the must-haves in one command. Or read on and pick.

---

## One tool per language, and the alternatives stay off the machine

The rule: **two version managers for one language is how a shell resolves the wrong
interpreter and doesn't tell you.** Every choice below follows from that.

| language | use | not | why |
|---|---|---|---|
| Python | **uv** | pyenv, conda, bare `venv`, `pip` | uv is the interpreter manager *and* the package manager. One tool, one lockfile. `uv python install --default` puts `python`/`python3` in `~/.local/bin`, so there is exactly one answer to `command -v python`. |
| Node | **nvm** | brew node, volta, fnm | Several versions resident at once is the one thing nvm is genuinely good at. But see the caveat below — it is also the single slowest thing in a shell startup. |
| Go | **brew go** | goenv, gvm | Since Go 1.21 the `toolchain` directive in `go.mod` fetches whatever a project asks for. A version manager on top is duplicated SDKs solving a solved problem. |
| Rust | **rustup** | `brew install rust` | They fight over `cargo` and `rustc` in `~/.cargo/bin` vs the brew prefix, and the resulting shell resolves whichever came first silently. Install with the one line from [rustup.rs](https://rustup.rs). |
| C/C++ | **cmake + ninja** | vcpkg, Conan | Nothing against them; they just weren't needed, and an unused package manager is a thing that rots. |

### Two things measured the hard way

**conda will win PATH and you won't notice.** On the machine this repo was written for,
conda's `python` sat ahead of everything else, so `pip3 install` succeeded into a prefix that
`python` never read. Worse, `uv` built venvs against it: `pyvenv.cfg` recorded
`home = .../miniconda/base/bin`, so deleting conda later broke every venv on the machine.
If you have conda and you're moving to uv, rebuild the venvs *after* conda is gone, not
before — see [`docs/manual.md`](manual.md).

**nvm costs ~950 ms per shell if you source it eagerly.** Measured at 942.8 ms, 71% of a
1332 ms startup. It does not have to be paid: symlink `node`/`npm`/`npx` from the nvm default
into `~/.local/bin` and *running* node needs no nvm at all — only *switching versions* does.
[`shell/conf.d/45-nvm.zsh`](../shell/conf.d/45-nvm.zsh) sources `nvm.sh` lazily, on the first
`nvm` you type.

---

## Two things macOS already ships — don't install them again

**git.** macOS ships Apple Git (2.54.0 on macOS 26.6.2) with the Xcode Command Line Tools,
which you need anyway. brew's is 2.55.0 — one minor version, in exchange for a second `git`
that shadows a working one the moment `/opt/homebrew/bin` precedes `/usr/bin`. Not worth it.

**jq.** `/usr/bin/jq`, Apple-signed as `com.apple.jq`. Relying on it is only safe because
this targets current macOS; on older releases you'd need brew's.

Both of these were once in the Brewfile. The line for git justified itself with "macOS ships
git 2.39" — wrong by fifteen minor versions. **Measured claims about other people's software
rot silently**, which is an argument for making fewer of them.

---

## The must-haves

Shell experience — the four that `shell/conf.d/80-plugins.zsh` and `90-p10k.zsh` expect:

| | |
|---|---|
| `powerlevel10k` | The prompt. Its `~/.p10k.zsh` is ~90 KB of wizard answers — run `p10k configure`, don't try to version it. |
| `zsh-autosuggestions` | Grey inline completion from history. ~60 ms of your startup, and worth it. |
| `zsh-completions` | Extra completion definitions on `$fpath`. |
| `fzf` | `Ctrl-R` that is actually usable. |
| `autojump` | `j <partial-dir>`. `zoxide` is the modern alternative; pick one, not both. |

Everyday:

| | |
|---|---|
| `ripgrep` | Assume it. Every search in this repo and every agent search does. |
| `gh` | `gh auth login --git-protocol ssh` authenticates *and* uploads an SSH key, creating one if you have none. That is the single best reason to install it. |
| `tmux` | Long builds survive a closed terminal. |
| `htop` | `top` can't sort by RSS interactively. |
| `gnupg` | Signed commits; `gpg-agent` for SSH keys. |
| `ollama` | The runner only. No weights — `ollama pull llama3.2:3b` when you want one (~2 GB). |

Shell hygiene, non-negotiable if you write any shell at all:

| | |
|---|---|
| `shellcheck` | Catches the quoting bug you were going to ship. |
| `shfmt` | Formatting drift in shell reads as spurious diffs in review. |
| `pre-commit` | Runs both locally, so CI isn't where you learn. |

## Worth having, install when you hit the need

`fd` · `bat` · `tree` · `eza` · `yq` · `direnv` · `zoxide` · `tectonic` · `redis` · `mkcert`
· `p7zip` · `poppler` · `gifsicle`

Two notes. **`eza`** is deliberately not aliased to `ls` by default — scripts that parse `ls`
break. **`tectonic`** is a self-contained LaTeX engine, which beats 5 GB of MacTeX for one
paper.

## GUI apps: listed, never installed

VS Code · iTerm2 · Claude Code · Google Chrome · Docker Desktop · Raycast · Obsidian

**No `cask` lines in either Brewfile, deliberately.** A cask in a bundle pops authentication
dialogs during an unattended run, and worse, silently reinstalls an app you already dragged
in from a `.dmg` — so `brew bundle check` stops agreeing with reality. Install these by hand,
or `brew install --cask <name>` one at a time, having read what it's about to do.
