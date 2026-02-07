.SECONDEXPANSION:
.SECONDARY:
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -ec
.DEFAULT_GOAL := help

MAKEFLAGS += --no-print-directory
MAKEFLAGS += --no-builtin-rules
MAKEFLAGS += --no-builtin-variables
MAKEFLAGS += --output-sync

o := o

export PATH := $(CURDIR)/$(o)/bin:$(PATH)

TMP ?= /tmp
export TMPDIR := $(TMP)

# cosmic dependency
cosmic_version := 2026-02-06-c7537ca
cosmic_url := https://github.com/whilp/cosmic/releases/download/$(cosmic_version)/cosmic-lua
cosmic_sha := 19f8991a9254f093b83546ecdf780c073b039600f060ab93f6ce78f1ef020bd8
cosmic := $(o)/bin/cosmic

$(cosmic): | $(o)/bin/.
	@echo "==> fetching cosmic $(cosmic_version)"
	@curl -fsSL -o $@ $(cosmic_url)
	@echo "$(cosmic_sha)  $@" | sha256sum -c - >/dev/null
	@chmod +x $@

# build tools
build_tools := $(o)/bin/make-help.lua $(o)/bin/reporter.lua $(o)/bin/run-test.lua

$(o)/bin/%.lua: lib/build/%.tl $(cosmic)
	@mkdir -p $(@D)
	@$(cosmic) --compile $< > $@

$(o)/bin/run-test.lua: lib/test/run-test.tl $(cosmic)
	@mkdir -p $(@D)
	@$(cosmic) --compile $< > $@

# ah module
ah_srcs := $(wildcard lib/ah/*.tl)
ah_tl := $(ah_srcs) bin/ah.tl
ah_lua := $(patsubst lib/%.tl,$(o)/lib/%.lua,$(ah_srcs)) $(o)/bin/ah.lua
ah_tests := $(wildcard lib/ah/test_*.tl)

# type declarations
types := $(wildcard lib/types/*.d.tl lib/types/*/*.d.tl)
TL_PATH := $(CURDIR)/lib/types/?.d.tl;$(CURDIR)/lib/types/?/init.d.tl;$(CURDIR)/$(o)/lib/?.tl;$(CURDIR)/$(o)/lib/?/init.tl;$(CURDIR)/lib/?.tl;$(CURDIR)/lib/?/init.tl

# compile .tl to .lua
$(o)/lib/%.lua: lib/%.tl $(types) $(cosmic)
	@mkdir -p $(@D)
	@$(cosmic) --compile $< > $@

$(o)/bin/%.lua: bin/%.tl $(types) $(cosmic)
	@mkdir -p $(@D)
	@$(cosmic) --compile $< > $@

# standalone lib files
$(o)/lib/ulid.lua: lib/ulid.tl $(types) $(cosmic)
	@mkdir -p $(@D)
	@$(cosmic) --compile $< > $@

# tests
all_tests := $(ah_tests)
all_tested := $(patsubst %,$(o)/%.test.ok,$(all_tests))

export TEST_O := $(o)
export TEST_BIN := $(o)/bin
export LUA_PATH := $(CURDIR)/o/bin/?.lua;$(CURDIR)/o/lib/?.lua;$(CURDIR)/o/lib/?/init.lua;$(CURDIR)/lib/?.lua;$(CURDIR)/lib/?/init.lua;;
export NO_COLOR := 1

$(o)/%.tl.test.ok: $(o)/%.lua $(ah_lua) $(o)/bin/run-test.lua $(cosmic)
	@mkdir -p $(@D)
	@[ -x $< ] || chmod a+x $<
	-@$(cosmic) $(o)/bin/run-test.lua $< > $@

# targets
.PHONY: help
help: $(build_tools) $(cosmic)
	@$(cosmic) $(o)/bin/make-help.lua $(MAKEFILE_LIST)

.PHONY: test
## Run all tests (incremental)
test: $(o)/test-summary.txt

$(o)/test-summary.txt: $(all_tested) $(o)/bin/reporter.lua $(cosmic)
	@$(cosmic) $(o)/bin/reporter.lua --dir $(o) $(all_tested) | tee $@

.PHONY: build
## Build all files
build: $(ah_lua)

.PHONY: teal
## Run teal type checker on all files
teal: $(o)/teal-summary.txt

all_teals := $(patsubst %,$(o)/%.teal.ok,$(ah_tl))

$(o)/teal-summary.txt: $(all_teals) $(o)/bin/reporter.lua $(cosmic)
	@$(cosmic) $(o)/bin/reporter.lua --dir $(o) $(all_teals) | tee $@

$(o)/%.tl.teal.ok: %.tl $(cosmic) $(types)
	@mkdir -p $(@D)
	@if TL_PATH='$(TL_PATH)' $(cosmic) --check "$<" >/dev/null 2>$@.err; then \
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

%/.:
	@mkdir -p $@
