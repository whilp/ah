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
cosmic_version := 2026-02-10-6ea0370
cosmic_url := https://github.com/whilp/cosmic/releases/download/$(cosmic_version)/cosmic-lua
cosmic_sha := 2e3390eca438550a4ee54ed6007cbfbca89f112befcd21b8465ef3f9e8f12cd0
cosmic := $(o)/bin/cosmic

.PHONY: cosmic
cosmic: $(cosmic)
$(cosmic):
	@mkdir -p $(@D)
	@echo "==> fetching cosmic $(cosmic_version)"
	@curl -fsSL -o $@ $(cosmic_url)
	@echo "$(cosmic_sha)  $@" | sha256sum -c - >/dev/null
	@chmod +x $@

reporter := $(cosmic) lib/build/reporter.tl

# ah module
ah_srcs := $(wildcard lib/ah/*.tl) bin/ah.tl
ah_lua := $(patsubst %.tl,$(o)/%.lua,$(ah_srcs))
ah_tests := $(wildcard lib/ah/test_*.tl)
ah_lib_srcs := $(filter-out $(ah_tests),$(wildcard lib/ah/*.tl))
ah_lib_lua := $(patsubst lib/ah/%.tl,$(o)/embed/.lua/ah/%.lua,$(ah_lib_srcs))
ah_dep_srcs := $(wildcard lib/*.tl)
ah_dep_lua := $(patsubst lib/%.tl,$(o)/embed/.lua/%.lua,$(ah_dep_srcs))

TL_PATH := lib/?.tl;lib/?/init.tl;/zip/.lua/?.tl;/zip/.lua/?/init.tl;/zip/.lua/types/?.d.tl;/zip/.lua/types/?/init.d.tl

# compile .tl to .lua
$(o)/%.lua: %.tl $(cosmic)
	@mkdir -p $(@D)
	@$(cosmic) --compile $< > $@

# tests
all_tested := $(patsubst %,$(o)/%.test.ok,$(ah_tests))

export LUA_PATH := $(CURDIR)/o/bin/?.lua;$(CURDIR)/o/lib/?.lua;$(CURDIR)/o/lib/?/init.lua;$(CURDIR)/lib/?.lua;$(CURDIR)/lib/?/init.lua;;

$(o)/%.tl.test.ok: $(o)/%.lua $(ah_lua) $(cosmic)
	@mkdir -p $(@D)
	@d=$$(mktemp -d); TEST_TMPDIR=$$d $(cosmic) $< >$$d/out 2>&1 \
		&& echo "pass:" > $@ || echo "fail:" > $@; \
	cat $$d/out >> $@; rm -rf $$d

# targets
.PHONY: help
help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  test                Run all tests (incremental)"
	@echo "  build               Build all files"
	@echo "  ah                  Build ah executable archive"
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

$(o)/embed/embed/sys/%: sys/%
	@mkdir -p $(@D)
	@cp $< $@

ah_sys_files := $(shell find sys -type f 2>/dev/null)
ah_sys := $(patsubst sys/%,$(o)/embed/embed/sys/%,$(ah_sys_files))

$(o)/bin/ah: $(o)/embed/main.lua $(ah_lib_lua) $(ah_dep_lua) $(ah_sys) $(cosmic)
	@echo "==> embedding ah"
	@$(cosmic) --embed $(o)/embed --output $@

.PHONY: ah
## Build ah executable archive
ah: $(o)/bin/ah

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

.PHONY: clean
## Remove all build artifacts
clean:
	@rm -rf $(o)
