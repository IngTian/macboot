# Manual steps

Everything macboot cannot do for you, with the reason it cannot. None of these are
"not implemented yet". Each one is either a GUI consent gate that exists precisely
so a script cannot pass it, or something I tried to automate and reverted because a
script that half-works is worse than two clicks you remember making.

Work through this list once, after `make all`.

- [ ] Raycast on ⌘-Space, Spotlight off it
- [ ] Xcode Command Line Tools (if `00-preflight.sh` sent you here)
- [ ] App Store sign-in, App Store apps
- [ ] App licences, and 2FA on the accounts behind them
- [ ] Change your login shell — only if it is not already zsh (see §5)
- [ ] Select the `manifold` screensaver
- [ ] Full Disk Access for Terminal/iTerm — only if you want it
- [ ] **A custody plan for your SSH private keys**
- [ ] **A backup**

---

## 1. Raycast on ⌘-Space

Two steps, in this order:

1. Raycast → Settings → General → **Raycast Hotkey** → record ⌘-Space. macOS will
   report a conflict; that is expected.
2. System Settings → Keyboard → Keyboard Shortcuts… → **Spotlight** → untick
   *Show Spotlight search*.

Do Raycast first. If you free up ⌘-Space before Raycast claims it, you get a
several-minute window where the key does nothing, and on a fresh machine that feels
like the bootstrap broke something.

**Why this is not automated.** The Spotlight side lives in
`com.apple.symbolichotkeys`, under `AppleSymbolicHotKeys` → key `"64"`
(*Show Spotlight search*) and `"65"` (*Show Finder search window*). Three separate
problems, each enough on its own:

- The value is a **nested dictionary** — `{enabled = 0; value = {parameters = (32,
  49, 1048576); type = standard;};}` — and `defaults write` cannot reach into a
  nested key. You have to read the whole `AppleSymbolicHotKeys` dict, splice one
  entry, and write the entire dict back, which means a bug in the splice silently
  discards every *other* shortcut the user had customised.
- It **needs the preference daemon restarted** to take effect —
  `killall cfprefsd`, plus `activateSettings -u`, and realistically a log-out. A
  bootstrap step that only works after the next login is not a bootstrap step.
- Worst: it **silently no-ops against a cached domain.** `cfprefsd` may be holding
  `com.apple.symbolichotkeys` in memory when you write it, so the write succeeds,
  `defaults read` shows your new value, and the running WindowServer never sees it —
  then the cache flushes and overwrites your file with the old value. The script
  reports success, `⌘-Space` still opens Spotlight, and you go looking for the bug
  in your Raycast config.

Two clicks beats a script that half-works, so this stays in the checklist above.

## 2. Xcode Command Line Tools

```sh
xcode-select --install
```

`00-preflight.sh` checks for the CLT and dies if they are missing, because git,
`cc` and every compiled formula depend on them.

**Why not automated.** `xcode-select --install` does not install anything itself —
it asks `softwareupdate` to raise a **modal GUI dialog** with *Install* and
*Agree to the licence* buttons, and returns immediately. There is no supported
headless path for the standalone CLT package: the alternatives are accepting a
licence on the user's behalf (I will not do that in a script that runs on someone
else's machine) or downloading full Xcode from an authenticated Apple account.
Click the button, wait for it, re-run `make all`.

## 3. App Store apps and signing in

Sign in to the App Store with your Apple ID, then install whatever you keep there.

**Why not automated.** The sign-in is Apple ID authentication with 2FA — a code
delivered to another device. There is nothing for a script to do. This is also the
reason `apps.tsv` lists GUI apps rather than installing them: once App Store apps
need a human anyway, `mas` buys you nothing and adds a dependency that breaks every
time StoreKit changes.

## 4. App licences and 2FA

Licence keys and paid-app activation, plus enabling 2FA on GitHub and anything else
that matters.

**Why not automated.** A licence key is a secret and this repo holds no secrets —
see the README. Every path to automating it ends in "commit the key" or "fetch the
key from a vault this bootstrap would then have to unlock", and unlocking the vault
is the same problem one level down. Type them in once.

## 5. Change your login shell

Almost certainly unnecessary: macOS has shipped zsh as the default login shell since
Catalina, and `20-shell.sh` tells you which shell your account record actually has. Do
this only if it says you are not on zsh.

```sh
chsh -s /bin/zsh          # the shell macboot's config is written for
```

**Use the path `20-shell.sh` printed**, which is a zsh already listed in
`/etc/shells`.

**Do not paste `chsh -s "$(brew --prefix)/bin/zsh"`.** Earlier versions of this file
did, and it cannot work: `zsh` is in neither `Brewfile` nor `Brewfile.optional`, so
that path does not exist after a full macboot run — and even after
`brew install zsh`, `chsh` refuses any shell not listed in `/etc/shells`, which on a
stock Mac contains only `/bin/*` entries. Homebrew's zsh needs its path appended to
that root-owned file first:

```sh
sudo sh -c 'echo /opt/homebrew/bin/zsh >> /etc/shells'   # only if you want brew's zsh
```

**Why not automated.** `chsh` authenticates through PAM, which means an **interactive
password prompt on a TTY** — it does not read stdin from a pipe, and `sudo chsh` just
moves the prompt. Automating it means the script holding your account password.

## 6. Select the `manifold` screensaver

System Settings → Screen Saver → pick **manifold**.

`make mytools` builds the `.saver` bundle and installs it to
`~/Library/Screen Savers/`, so it will be in the list. It does not select it.

**Why not automated.** The selection is not a stable `defaults` domain any more. It
moved out of `com.apple.screensaver` into the wallpaper/screensaver store under
`~/Library/Application Support/com.apple.wallpaper/`, which is an opaque
per-display index that `WallpaperAgent` owns and rewrites — writing it behind the
agent's back gets your change discarded, or resets your desktop picture, or leaves
a display with no configuration at all. A third-party `.saver` also has to be
loaded once by the picker before the engine will run it. One click, once, forever.

## 7. Full Disk Access for Terminal or iTerm

Only if you want it: System Settings → Privacy & Security → Full Disk Access → add
your terminal.

**Why not automated.** Full Disk Access is a TCC grant, and the TCC database is
protected by SIP — it is not writable even by root, by design. The only two ways in
are a human clicking in System Settings or an MDM privacy-preferences payload, and
macboot explicitly does not do MDM. A script that could grant itself FDA would be a
macOS vulnerability, not a feature.

## 8. SSH private key custody — unsolved, on purpose

**This is the one item on this page that is a genuinely open problem, not a
consent dialog.**

A public bootstrap cannot manage private keys and should not try. It cannot
generate them for you (a new key is useless until every host you use has the new
public half), it cannot fetch them (fetching from where? unlocked with what?), and
it certainly cannot store them. So macboot does none of it, and hands you the
problem explicitly rather than leaving you to notice it at the worst moment.

What you have to do yourself, before you need it:

- Enumerate the keys that gate something you cannot re-create. On the machine this
  repo was written for that is three, gating two GitLab hosts, GitHub, and a peer
  machine over SSH.
- Decide where the second copy lives: a password manager with a secure-note or file
  attachment, or a hardware token, or — at absolute minimum — **one more copy
  somewhere that is not this laptop.** An encrypted archive on a USB stick in a
  drawer counts. A file in `~/Documents` does not; that is the same disk failing at
  the same time as everything else on it.
- Verify the copy by actually using it, once, from somewhere else. An untested
  backup is a belief, not a backup.

The failure mode is not "I have to make a new key". It is losing access to a host
you no longer have another way of authenticating to, on the day the disk dies.

## 9. Set up a backup

Turn on Time Machine, or something equivalent, and point it at a destination that
is not the internal disk.

**Why it warns on every run.** `00-preflight.sh` runs `tmutil destinationinfo`, and
when it reports *"No destinations configured"* it warns — every single run, with no
way to silence it. That is deliberate. It was true on the machine this repo was
built for while four repos held commits that existed in exactly one place, and a
worktree under `/private/tmp` had already been deleted by macOS's own tmp cleanup,
taking its commits with it. That is what a suppressible warning costs.

Nothing in macboot is a substitute for setting one up. It has no view of your data at
all: not your photos, not `~/Downloads`, not the licence keys from step 4, not whether
your git commits exist anywhere but this disk. The warning is the entirety of what it
does about backups, on purpose — enrolling a disk in Time Machine can erase it, so that
choice stays yours.

## Rust, if you ever need it

macboot does not install Rust: nothing in the must-have set needs it. It only stays out
of the way — `rust` is deliberately absent from the Brewfile, and `~/.cargo/bin` is
already on PATH for when you add it.

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

Use rustup rather than `brew install rust`: both want to own `cargo` and `rustc` on
PATH, and the resulting shell resolves whichever came first without telling you.
