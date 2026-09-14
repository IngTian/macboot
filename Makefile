# macboot — developer surface. Every target is safe to re-run, and every target
# that mutates the machine has a *-plan twin that prints the same run as
# "would <command>" and changes nothing.
#
# Modules are selected by their numeric prefix (--only 10) rather than their
# filename. The prefixes are the run order the spec fixes; the names after them
# have already churned once (the gate was rescue-check before check-unpushed),
# and a Makefile that hardcodes a name breaks silently on the rename by matching
# nothing.

SHELL := /bin/bash
# NOTE: .SHELLFLAGS was added in GNU Make 3.82 and stock macOS ships 3.81, so on the
# machine this repo targets these flags are SILENTLY IGNORED -- verified with
# `make --version`. It is kept for anyone running a newer make (brew's gmake), but
# nothing here may depend on it: every multi-line recipe below handles its own
# failures explicitly (`|| exit 1`, `|| { ...; exit 1; }`). An earlier comment here
# claimed the opposite and named the exact failure mode it was not preventing.
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

BOOTSTRAP := ./bootstrap.sh
SHELLCHECK ?= shellcheck
SHFMT ?= shfmt

# Used by `fmt` and the `bash -n` sweep only. `lint` and `test` delegate to
# tests/lint.sh, which DISCOVERS files by walking the tree -- one source of truth for
# "what gets linted", so a new scripts/45-foo.sh cannot be missed. tests/ is included
# here because it was previously absent, which let `make lint` pass while CI (which
# runs tests/lint.sh) failed on the same tree, and guaranteed shfmt drift in the three
# test scripts `make fmt` never reformatted.
SH_FILES := $(wildcard *.sh) $(wildcard lib/*.sh) $(wildcard scripts/*.sh) \
            $(wildcard tests/*.sh)

.PHONY: help plan all optional optional-plan mytools mytools-plan apps \
        check lint fmt test module module-plan

##@ Start here
help: ## this list
	@printf 'macboot — targets\n'
	@awk 'BEGIN { FS = ":.*## " } \
	  /^##@/ { printf "\n%s\n", substr($$0, 5); next } \
	  /^[a-zA-Z0-9_.-]+:.*## / { printf "  %-14s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf '\nDRY_RUN=1 works on every target. ./bootstrap.sh --help lists all flags.\n'

plan: ## dry run: print every change, make none  <- start here
	@$(BOOTSTRAP) --dry-run

all: ## every module in order, 00 -> 99 (resumes; --restart to redo)
	@$(BOOTSTRAP)

##@ Tiers
optional-plan: ## dry run of `optional`
	@$(BOOTSTRAP) --dry-run --optional --only 10

optional: ## Brewfile.optional — the nice-to-have formulae
	@$(BOOTSTRAP) --optional --only 10

mytools-plan: ## dry run of `mytools`
	@$(BOOTSTRAP) --dry-run --mytools --only 80

mytools: ## build my own tools; skips the private one
	@$(BOOTSTRAP) --mytools --only 80

apps: ## print the GUI apps that are missing, with paste-ready commands
	@$(BOOTSTRAP) --only 99 --yes

##@ Gates and quality
check: ## migrating off a Mac? non-zero while any commit exists only on this disk
	@# Calls the tool directly. It is NOT a bootstrap module: macboot sets up a BRAND
	@# NEW Mac, where there are no repositories to check, and a published bootstrap
	@# that refuses to proceed because a stranger's repo has an unpushed commit is a
	@# hostile default. As a module it also could not tell "you have unpushed work"
	@# apart from its own internal failures -- with git off PATH it printed an empty
	@# findings list and accused the user anyway.
	@bash check-unpushed.sh --report

lint: ## shellcheck + shfmt -d over every shell file in the tree
	@command -v $(SHELLCHECK) >/dev/null || \
	  { echo 'shellcheck missing: brew install shellcheck (it is in the Brewfile)'; exit 1; }
	@command -v $(SHFMT) >/dev/null || \
	  { echo 'shfmt missing: brew install shfmt (it is in the Brewfile)'; exit 1; }
	@bash tests/lint.sh

fmt: ## rewrite every script with shfmt (the plan equivalent is `lint`)
	$(SHFMT) -i 2 -ci -w $(SH_FILES)

test: lint ## lint, bash -n, then the real tests: purity, bootstrap flow, idempotency
	@# One `bash -n` per file: `bash -n a.sh b.sh` parses a.sh and passes the rest
	@# as positional parameters, so it silently checks exactly one file.
	@for f in $(SH_FILES); do bash -n "$$f" || exit 1; done; echo 'syntax: ok'
	@# These two scripts ARE the test suite, and this target used to reimplement a
	@# weaker version of the first one instead of calling either. The reimplementation
	@# was a transcript grep with no filesystem assertion at all, which
	@# tests/dry-run-purity.sh's own header explains is worthless -- a module that
	@# writes via a redirect instead of run() prints nothing, so the grep stays quiet
	@# on the one bug that matters. Its forbidden-verb list was also a strict subset
	@# (no mkdir, touch, cp, chmod, git, gh, uv, pip, npm, sudo, launchctl, or any
	@# `>` redirect), and its `^[[:space:]]*would ` filter missed any line whose first
	@# character is a glyph -- so `▸ would run: nvm install ...` failed the check on
	@# any machine without ~/.nvm. Meanwhile tests/double-run.sh, the only test that
	@# verifies idempotency at all, was reachable from no target.
	@bash tests/dry-run-purity.sh
	@bash tests/bootstrap-markers.sh
	@bash tests/check-unpushed.sh
	@bash tests/double-run.sh

##@ One module at a time
module-plan: ## dry run of `module`
	@test -n '$(M)' || { echo 'usage: make module-plan M=40-node'; exit 1; }
	@$(BOOTSTRAP) --dry-run --only '$(M)'

module: ## run one module: make module M=40-node (also 40, node, 40-node.sh)
	@test -n '$(M)' || { echo 'usage: make module M=40-node'; exit 1; }
	@$(BOOTSTRAP) --only '$(M)'
