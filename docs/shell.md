# Shell

A zsh layout where `~/.zshrc` is **one line and never grows**. This is the part of this repo
I'd most argue for keeping, because it's the one piece that's machinery rather than advice —
and because it's what made two real performance bugs findable.

## The problem it solves

The machine this replaced had a 242-line `.zshrc` in which `~/.local/bin` was prepended twice
and conda base twice, because nvm, conda, gcloud, oh-my-zsh, p10k, bun and opencode had each
appended a block over two years and nothing ever removed one. **No single line was wrong; the
file was.** Every installer appends. Nothing subtracts.

## The layout

```
~/.zshrc                              one fenced `source` line. That's all.
  └── ~/.config/macboot/rc.zsh        a symlink you own…
        └─→ <checkout>/shell/rc.zsh    …pointing at the loader
              ├── shell/conf.d/*.zsh           mine, versioned
              └── ~/.config/zsh/conf.d/*.zsh   yours, private
```

Your `.zshrc` becomes exactly this:

```zsh
if [[ -r "$HOME/.config/macboot/rc.zsh" ]]; then
  source "$HOME/.config/macboot/rc.zsh"
fi
```

The middle symlink is worth the hop: the line in `.zshrc` names a stable path, so moving or
renaming the checkout means re-pointing one symlink instead of editing `.zshrc`. And
`rc.zsh` finds its units with `${0:A:h}/conf.d` — `:A` resolves the symlink — so the units
always come from the same checkout as the loader. One link to maintain, not twelve.

`if/then` rather than `[[ -r … ]] && source …`: as the last statement of `.zshrc` the `&&`
form leaves `$?` non-zero whenever the file is absent, and a themed prompt draws an error
marker on the first prompt of every shell.

## How the merge works

This is the whole design, and it's four lines:

```zsh
typeset -A _macboot_units
for f in $rc_dir/conf.d/*.zsh(N) $USER_DIR/*.zsh(N); do
  _macboot_units[${f:t}]=$f          # keyed by BASENAME
done
for k in ${(ko)_macboot_units}; do source $_macboot_units[$k]; done
```

An associative array keyed by filename, filled from my directory **first** and yours
**second**. Therefore:

- **Same filename → yours wins completely.** `~/.config/zsh/conf.d/70-aliases.zsh` means mine
  is never sourced. An *empty* file of that name disables my aliases entirely.
- **Different filename → both load**, interleaved in filename order.
- `(N)` is nullglob, so an empty user directory isn't an error.

That override-by-name property is why nothing belongs in `.zshrc`. A block in an rc file can
only be *edited*; a unit can be *replaced*. When this repo still had an installer, it wrote a
second fence into `.zshrc` for nvm — and that block couldn't be overridden, which is exactly
the argument for moving it into `45-nvm.zsh`.

## The numbering contract

One hard boundary. Break it and things get slow, not broken:

| range | rule |
|---|---|
| below 50 | may add to `$fpath`. Completions are **not** loaded yet. |
| **50** | `compinit` runs, exactly once |
| above 50 | may rely on completions and on the final keymap |

**A vendor completion snippet belongs above 50.** Many of them end with "if `compdef` is not
defined, run `compinit`" — so below 50 they run a *second* full `compinit` of their own.
Measured: gcloud's `completion.zsh.inc` cost **297 ms** at `20-gcloud.zsh` and almost nothing
at `60-gcloud.zsh`. That was a real mistake made while writing this repo, not a hypothetical.

Use two digits — the sort is lexical, so `9-foo.zsh` runs *after* `80-plugins.zsh`.

## The units

| unit | what |
|---|---|
| `00-path` | `typeset -U path fpath`, then builds `$path`: `~/.local/bin`, brew, `~/go/bin`, `~/.cargo/bin`. The dedup is what stops the duplicated-PATH problem at the source. |
| `05-p10k-instant` | p10k's instant prompt. **The one unit whose position is load-bearing** — see below. |
| `10-history` | 200k lines, shared across windows, dedup, and `HIST_IGNORE_SPACE` so a leading space keeps a token out of the file. |
| `20-options` | Three `setopt`s. `INTERACTIVE_COMMENTS` (paste a commented command without a syntax error), `NO_BEEP`, and `NO_FLOW_CONTROL` so `^S`/`^Q` can't freeze your terminal for good. |
| `30-fpath` | brew's `zsh-completions` and `site-functions` onto `$fpath`. |
| `45-nvm` | A lazy `nvm` shim. Eager was 943 ms. |
| `50-compinit` | The single `compinit`, with a dump rebuilt only if older than a day. |
| `60-keys` | `bindkey -e` explicitly (zsh picks vi silently if `$EDITOR` matches), up/down do prefix search, ctrl-arrow word jumps, fn-delete. |
| `70-aliases` | `eza`/`bat` if present, git shortcuts, `..`/`...`, `mkcd`, `ports`, `reload`, `zprofile`. |
| `80-plugins` | autosuggestions, fzf completion + key-bindings, autojump. ~60 ms, the real cost of the features. |
| `90-p10k` | The theme, after the plugins so the prompt wins over their ZLE widgets, then your `~/.p10k.zsh`. |

### The one ordering hazard

p10k's instant prompt refuses to replay its cached prompt if **anything** writes to the
console first — it prints a multi-paragraph warning and the prompt jumps. So `05` must precede
every unit that can print.

That holds today only because the other units are silent on a normal start: `80-plugins`
prints only when `autojump.sh` is missing, `50-compinit` only under
`MACBOOT_ZSH_COMPAUDIT`. **Add a unit below 05 that prints and you break the instant prompt,
and the symptom will look like a p10k bug rather than an ordering one.**

## Measuring it

```zsh
zprofile        # alias for: MACBOOT_ZSH_PROFILE=1 exec zsh
```

Per-unit milliseconds. This is the reason the layout is worth having: a 943 ms nvm load and a
297 ms misplaced `compinit` were both invisible when they lived in `.zshrc`, because a
profiler can only time what it loads. Reducing `.zshrc` to one line is what made them
measurable.

`05-p10k-instant` skips itself while profiling, because the profiler's own output is exactly
what the instant prompt forbids — otherwise every measurement ends with a p10k warning the
tool caused itself.

## Adopting it

Symlink, if you want `git pull` to deliver updates:

```bash
mkdir -p ~/.config/macboot ~/.config/zsh/conf.d
ln -s "$PWD/shell/rc.zsh" ~/.config/macboot/rc.zsh
```

Or copy `shell/` somewhere of your own and point the symlink there — then nothing in your
shell depends on this repo. Either way, add the four-line fence to `.zshrc` and put your own
units in `~/.config/zsh/conf.d/`.

**One deliberate coupling to understand before you symlink:** with the link in place, a
`git pull` here changes your shell. That's the point if you want updates and a hazard if you
don't. Copying instead of linking is the decoupled choice, and it's a legitimate one.

Not covered, on purpose: **`~/.zshenv`**. If you need a tool on `PATH` for non-interactive
shells — hooks, LaunchAgents, cron — that goes in `.zshenv`, because `.zshrc` is read for
interactive shells only. A login-but-non-interactive shell reads `.zprofile` and skips
`.zshrc` entirely, which surprises people.
