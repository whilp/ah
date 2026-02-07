.SECONDARY:
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -ec
.DEFAULT_GOAL := help

MAKEFLAGS += --no-print-directory
MAKEFLAGS += --no-builtin-rules
MAKEFLAGS += --no-builtin-variables
MAKEFLAGS += --output-sync

o := o

TMP ?= /tmp
export TMPDIR := $(TMP)

# cosmic dependency
cosmic_version := 2026-02-06-c7537ca
cosmic_url := https://github.com/whilp/cosmic/releases/download/$(cosmic_version)/cosmic-lua
cosmic_sha := 19f8991a9254f093b83546ecdf780c073b039600f060ab93f6ce78f1ef020bd8
cosmic := $(o)/bin/cosmic

$(cosmic):
	@mkdir -p $(@D)
	@echo "==> fetching cosmic $(cosmic_version)"
	@curl -fsSL -o $@ $(cosmic_url)
	@echo "$(cosmic_sha)  $@" | sha256sum -c - >/dev/null
	@chmod +x $@

reporter := $(cosmic) lib/build/reporter.tl

# ah module
ah_srcs := $(wildcard lib/ah/*.tl)
ah_lua := $(patsubst lib/%.tl,$(o)/lib/%.lua,$(ah_srcs)) $(o)/bin/ah.lua
ah_tests := $(wildcard lib/ah/test_*.tl)

# type declarations
types := $(wildcard lib/types/*.d.tl lib/types/*/*.d.tl)
TL_PATH := lib/?.tl;lib/?/init.tl;lib/types/?.d.tl;lib/types/?/init.d.tl;/zip/.lua/?.tl;/zip/.lua/?/init.tl;/zip/.lua/types/?.d.tl;/zip/.lua/types/?/init.d.tl

# compile .tl to .lua
$(o)/%.lua: %.tl $(types) $(cosmic)
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
	@echo "  check-types         Run teal type checker on all files"
	@echo "  clean               Remove all build artifacts"

.PHONY: test
## Run all tests (incremental)
test: $(o)/test-summary.txt

$(o)/test-summary.txt: $(all_tested) $(cosmic)
	@$(reporter) --dir $(o) $(all_tested) | tee $@

.PHONY: build
## Build all files
build: $(ah_lua)

.PHONY: check-types
## Run teal type checker on all files
check-types: $(o)/teal-summary.txt

all_teals := $(patsubst %,$(o)/%.teal.ok,$(ah_srcs) bin/ah.tl)

$(o)/teal-summary.txt: $(all_teals) $(cosmic)
	@$(reporter) --dir $(o) $(all_teals) | tee $@

$(o)/%.tl.teal.ok: %.tl $(cosmic) $(types)
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

.PHONY: clean
## Remove all build artifacts
clean:
	@rm -rf $(o)
