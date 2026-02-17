.SECONDARY:
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -ec
.DEFAULT_GOAL := help

MAKEFLAGS += --no-print-directory
MAKEFLAGS += --no-builtin-rules
MAKEFLAGS += --no-builtin-variables
MAKEFLAGS += --output-sync
export COSMIC_NO_WELCOME = 1

o := o

TMP ?= /tmp
export TMPDIR := $(TMP)

# cosmic dependency
cosmic_version := 2026-02-17-93239ce
cosmic_url := https://github.com/whilp/cosmic/releases/download/$(cosmic_version)/cosmic-lua
cosmic_sha := f7847182ec5c1c205e34b5e99dd68ddb02e280fda0f9cad4ee7eb19fd52a4858
cosmic := $(o)/bin/cosmic

# stamp file tracks pinned version; if version changes the binary is re-fetched
cosmic_stamp := $(o)/bin/.cosmic-$(cosmic_version)

.PHONY: cosmic
cosmic: $(cosmic)
$(cosmic): $(cosmic_stamp)
$(cosmic_stamp):
	@mkdir -p $(@D)
	@rm -f $(cosmic) $(o)/bin/.cosmic-*
	@echo "==> fetching cosmic $(cosmic_version)"
	@curl -fsSL -o $(cosmic) $(cosmic_url)
	@echo "$(cosmic_sha)  $(cosmic)" | sha256sum -c - >/dev/null
	@chmod +x $(cosmic)
	@touch $@

# cosmic-debug dependency (with debug symbols)
cosmic_debug_url := https://github.com/whilp/cosmic/releases/download/$(cosmic_version)/cosmic-lua-debug
cosmic_debug_sha := 517426f6327123eebf781f114646002da7b0eb969aac785e5ce2c9340f936197
cosmic_debug := $(o)/bin/cosmic-debug
cosmic_debug_stamp := $(o)/bin/.cosmic-debug-$(cosmic_version)

.PHONY: cosmic-debug
cosmic-debug: $(cosmic_debug)
$(cosmic_debug): $(cosmic_debug_stamp)
$(cosmic_debug_stamp):
	@mkdir -p $(@D)
	@rm -f $(cosmic_debug) $(o)/bin/.cosmic-debug-*
	@echo "==> fetching cosmic-debug $(cosmic_version)"
	@curl -fsSL -o $(cosmic_debug) $(cosmic_debug_url)
	@echo "$(cosmic_debug_sha)  $(cosmic_debug)" | sha256sum -c - >/dev/null
	@chmod +x $(cosmic_debug)
	@touch $@

reporter := $(cosmic) lib/build/reporter.tl

# ah module
ah_srcs := $(wildcard lib/ah/*.tl) $(wildcard sys/tools/*.tl) bin/ah.tl
ah_lua := $(patsubst %.tl,$(o)/%.lua,$(ah_srcs))
ah_tests := $(wildcard lib/ah/test_*.tl)
ah_lib_srcs := $(filter-out $(ah_tests),$(wildcard lib/ah/*.tl))
ah_lib_lua := $(patsubst lib/ah/%.tl,$(o)/embed/.lua/ah/%.lua,$(ah_lib_srcs))
ah_dep_srcs := $(wildcard lib/*.tl)
ah_dep_lua := $(patsubst lib/%.tl,$(o)/embed/.lua/%.lua,$(ah_dep_srcs))

# version: tag if HEAD is tagged, otherwise yyyy-mm-dd-sha; append * if dirty
ah_version := $(shell \
  v=$$(git describe --tags --exact-match 2>/dev/null) || \
  v=$$(git log -1 --format='%cd-%h' --date=format:'%Y-%m-%d' 2>/dev/null) || \
  v=unknown; \
  if ! git diff --quiet 2>/dev/null; then v="$$v*"; fi; \
  echo "$$v")
ah_version_lua := $(o)/embed/.lua/ah/version.lua

TL_PATH := lib/?.tl;lib/?/init.tl;/zip/.lua/?.tl;/zip/.lua/?/init.tl;/zip/.lua/types/?.d.tl;/zip/.lua/types/?/init.d.tl

# compile .tl to .lua
$(o)/%.lua: %.tl $(cosmic)
	@mkdir -p $(@D)
	@TL_PATH='$(TL_PATH)' $(cosmic) --compile $< > $@

# tests
all_tested := $(patsubst %,$(o)/%.test.ok,$(ah_tests))

export LUA_PATH := $(CURDIR)/o/lib/?.lua;$(CURDIR)/o/lib/?/init.lua;$(CURDIR)/lib/?.lua;$(CURDIR)/lib/?/init.lua;;

$(o)/%.tl.test.ok: $(o)/%.lua $(ah_lua) $(cosmic)
	@mkdir -p $(@D)
	@d=$$(mktemp -d); TEST_TMPDIR=$$d $(cosmic) $< >$$d/out 2>&1 \
		&& echo "pass:" > $@ || echo "fail:" > $@; \
	if [ -f $$d/out ]; then cat $$d/out >> $@; fi; rm -rf $$d

# targets
.PHONY: help
help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  test                Run all tests (incremental)"
	@echo "  build               Build all files"
	@echo "  ah                  Build ah executable archive"
	@echo "  ah-debug            Build ah executable archive with debug symbols"
	@echo "  release             Create GitHub prerelease (RELEASE=1 for full)"
	@echo "  check-types         Run teal type checker on all files"
	@echo "  ci                  Run tests and type checks"
	@echo "  clean               Remove all build artifacts"

.PHONY: test
## Run all tests (incremental)
test: $(o)/test-summary.txt

$(o)/test-summary.txt: $(all_tested) $(cosmic)
	@$(reporter) --dir $(o) $(all_tested) | tee $@

.PHONY: build
## Build all files
build: $(ah_lua)

# embed staging
$(o)/embed/main.lua: $(o)/bin/ah.lua
	@mkdir -p $(@D)
	@cp $< $@

$(o)/embed/.lua/ah/%.lua: $(o)/lib/ah/%.lua
	@mkdir -p $(@D)
	@cp $< $@

$(o)/embed/.lua/%.lua: $(o)/lib/%.lua
	@mkdir -p $(@D)
	@cp $< $@

# generate version.lua from git state (always regenerated)
.PHONY: $(ah_version_lua)
$(ah_version_lua):
	@mkdir -p $(@D)
	@echo 'return "$(ah_version)"' > $@

# sys files: copy non-.tl files, compile .tl to .lua
$(o)/embed/embed/sys/%.lua: sys/%.tl $(cosmic)
	@mkdir -p $(@D)
	@TL_PATH='$(TL_PATH)' $(cosmic) --compile $< > $@

$(o)/embed/embed/sys/%: sys/%
	@mkdir -p $(@D)
	@cp $< $@

ah_sys_files_raw := $(shell find sys -type f 2>/dev/null)
ah_sys_tl := $(filter %.tl,$(ah_sys_files_raw))
ah_sys_other := $(filter-out %.tl,$(ah_sys_files_raw))
ah_sys := $(patsubst sys/%.tl,$(o)/embed/embed/sys/%.lua,$(ah_sys_tl)) \
          $(patsubst sys/%,$(o)/embed/embed/sys/%,$(ah_sys_other))

# embed ci reference files (the actual files this repo uses)
ah_ci_files := Makefile .github/workflows/test.yml
ah_ci := $(patsubst %,$(o)/embed/embed/ci/%,$(ah_ci_files))

$(o)/embed/embed/ci/%: %
	@mkdir -p $(@D)
	@cp $< $@

$(o)/bin/ah: $(o)/embed/main.lua $(ah_lib_lua) $(ah_dep_lua) $(ah_version_lua) $(ah_sys) $(ah_ci) $(cosmic)
	@echo "==> embedding ah"
	@$(cosmic) --embed $(o)/embed --output $@.tmp && mv $@.tmp $@

.PHONY: ah
## Build ah executable archive
ah: $(o)/bin/ah

$(o)/bin/ah-debug: $(o)/embed/main.lua $(ah_lib_lua) $(ah_dep_lua) $(ah_version_lua) $(ah_sys) $(ah_ci) $(cosmic_debug)
	@echo "==> embedding ah-debug"
	@$(cosmic_debug) --embed $(o)/embed --output $@.tmp && mv $@.tmp $@

.PHONY: ah-debug
## Build ah executable archive with debug symbols
ah-debug: $(o)/bin/ah-debug

.PHONY: check-types
## Run teal type checker on all files
check-types: $(o)/teal-summary.txt

all_teals := $(patsubst %,$(o)/%.teal.ok,$(ah_srcs))

$(o)/teal-summary.txt: $(all_teals) $(cosmic)
	@$(reporter) --dir $(o) $(all_teals) | tee $@

$(o)/%.tl.teal.ok: %.tl $(cosmic)
	@mkdir -p $(@D)
	@if TL_PATH='$(TL_PATH)' $(cosmic) --check-types "$<" >/dev/null 2>$@.err; then \
		echo "pass:" > $@; \
	else \
		n=$$(grep -c ': error:' $@.err 2>/dev/null || echo 0); \
		echo "fail: $$n issues" > $@; \
		echo "" >> $@; echo "## stderr" >> $@; echo "" >> $@; \
		grep ': error:' $@.err >> $@ 2>/dev/null || true; \
	fi; \
	rm -f $@.err

.PHONY: ci
## Run tests and type checks
ci: test check-types

.PHONY: check
check: ci

$(o)/bin/SHA256SUMS: $(o)/bin/ah $(o)/bin/ah-debug
	@cd $(o)/bin && sha256sum ah ah-debug > SHA256SUMS

.PHONY: release
## Create GitHub release with ah and ah-debug binaries
## Set RELEASE=1 for a full release (default is prerelease)
release: $(o)/bin/SHA256SUMS
	@tag=$(ah_version); \
	echo "==> creating release $$tag"; \
	gh release delete "$$tag" --yes 2>/dev/null || true; \
	gh release create "$$tag" \
		--title "$$tag" \
		--generate-notes \
		$(if $(filter 1,$(RELEASE)),,--prerelease) \
		$(o)/bin/ah \
		$(o)/bin/ah-debug \
		$(o)/bin/SHA256SUMS


.PHONY: clean
## Remove all build artifacts
clean:
	@rm -rf $(o)
