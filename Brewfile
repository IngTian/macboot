# macboot — must-have formulae. The toolchain everything downstream assumes.
#
# No `cask` lines here or in Brewfile.optional, ever (spec D8): GUI apps are
# listed in apps.tsv and installed by hand. A cask in a Brewfile makes an
# unattended run pop authentication dialogs and, worse, silently reinstalls an
# app the user already dragged in from a .dmg, so `brew bundle check` never
# agrees with reality and no run can report changed=0.
#
# No `tap` lines either: every formula below is in homebrew/core, and a tap that
# 404s (renamed, archived) aborts the whole bundle before anything installs.
#
# Deliberately absent: rust (rustup owns it — brew's rust and rustup fight over
# ~/.cargo/bin), python (uv owns it), node (nvm owns it), goenv/vcpkg/miniconda
# (being retired). See the spec's decision table.

# NO `brew "git"`. 00-preflight.sh DIES without the Xcode CLT, so the CLT's git is a hard
# prerequisite and is therefore always present by the time this file is read -- on a fresh
# Mac too. Measured on macOS 26.6.2: Apple Git 2.54.0 against brew's 2.55.0, i.e. one minor
# version, and nothing in this Brewfile pulls git as a dependency (checked with `brew deps`
# over every formula here). A second git that shadows a working one once /opt/homebrew/bin
# leads /usr/bin is not worth one minor version. The line that used to be here justified
# itself with "macOS ships git 2.39", which was wrong by fifteen minor versions -- exactly
# the kind of measured claim about someone else's software that rots silently.
brew "gh"                  # 80-mytools.sh probes the private repo with it; `gh auth setup-git` is how git gets a credential
brew "zsh-autosuggestions" # 20-shell.sh sources it from $(brew --prefix)/share
brew "zsh-completions"     # ditto; must exist before the .zshrc fpath line points at it
brew "fzf"                 # Ctrl-R history search that 20-shell.sh wires up
brew "tmux"                # long-running builds survive a terminal close
brew "htop"                # `top` cannot sort by RSS interactively
brew "autojump"            # `j <dir>`; the .zshrc block is dead weight without it
brew "ripgrep"             # every script and every agent search in this repo assumes rg
# Kept even though recent macOS ships /usr/bin/jq (Apple-signed, com.apple.jq): it is
# absent on older macOS, and this repo states no minimum version. Deliberately no version
# number in this comment -- the git line above is what happens when one goes stale.
brew "jq"                  # apps.tsv/plist inspection; also 70-claude.sh, if it ever merges settings.json
brew "gnupg"               # signed commits; also gpg-agent for the SSH keys named in the spec
brew "go"                  # per the decision table: brew go, no goenv (go.mod toolchain since 1.21)
brew "cmake"               # C/C++ is cmake + ninja only, no vcpkg, no Conan
brew "ninja"               # the generator cmake is configured against
brew "shellcheck"          # non-negotiable: this repo *is* shell, and it gates CI on day one
brew "shfmt"               # ditto — formatting drift in shell shows up as spurious diffs
brew "pre-commit"          # runs the two above locally so CI is not the first place lint fails
brew "ollama"              # the runner only — NO weights are pulled; see the hint 10-brew.sh prints
