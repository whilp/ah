.SECONDEXPANSION:
.SECONDARY:
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -ec
.DEFAULT_GOAL := help

MAKEFLAGS += --no-print-directory
MAKEFLAGS += --no-builtin-rules
MAKEFLAGS += --no-builtin-variables
MAKEFLAGS += --output-sync

modules :=
o := o

export PATH := $(CURDIR)/$(o)/bin:$(PATH)
export STAGE_O := $(CURDIR)/$(o)/staged
export FETCH_O := $(CURDIR)/$(o)/fetched

# TL_PATH for teal type checker
TL_PATH := $(CURDIR)/lib/types/?.d.tl;$(CURDIR)/lib/types/?/init.d.tl;$(CURDIR)/$(o)/lib/?.tl;$(CURDIR)/$(o)/lib/?/init.tl;$(CURDIR)/lib/?.tl;$(CURDIR)/lib/?/init.tl

TMP ?= /tmp
export TMPDIR := $(TMP)

uname_s := $(shell uname -s)
uname_m := $(shell uname -m)
os := $(if $(filter Darwin,$(uname_s)),darwin,linux)
arch := $(subst aarch64,arm64,$(uname_m))
platform := $(os)-$(arch)

include bootstrap.mk
include 3p/cosmic/cook.mk
include lib/ah/cook.mk
include cook.mk

cp := cp -p

$(o)/%: %
	@mkdir -p $(@D)
	@$(cp) $< $@

# compile .tl files to .lua
$(o)/%.lua: %.tl $(types_files) | $(bootstrap_files)
	@mkdir -p $(@D)
	@$(bootstrap_cosmic) --compile $< > $@

# define *_staged, *_dir for versioned modules
$(foreach m,$(modules),$(if $($(m)_version),\
  $(eval $(m)_staged := $(o)/$(m)/.staged)\
  $(if $($(m)_dir),,$(eval $(m)_dir := $(o)/$(m)/.staged))))

# expand module deps
$(foreach m,$(modules),\
  $(foreach d,$($(m)_deps),\
    $(eval $($(m)_files): $($(d)_files))\
    $(if $($(d)_staged),\
      $(eval $($(m)_files): $($(d)_staged)))))

# versioned modules: o/module/.versioned -> version.lua
$(foreach m,$(modules),$(if $($(m)_version),\
  $(eval $(o)/$(m)/.versioned: $($(m)_version) ; @mkdir -p $$(@D) && ln -sfn $(CURDIR)/$$< $$@)))
all_versioned := $(foreach m,$(modules),$(if $($(m)_version),$(o)/$(m)/.versioned))

# fetch dependencies
.PHONY: fetched
all_fetched := $(patsubst %/.versioned,%/.fetched,$(all_versioned))
fetched: $(all_fetched)
$(o)/%/.fetched: $(o)/%/.versioned $(build_files) | $(bootstrap_cosmic)
	@$(build_fetch) $$(readlink $<) $(platform) $@

# stage dependencies
.PHONY: staged
all_staged := $(patsubst %/.fetched,%/.staged,$(all_fetched))
staged: $(all_staged)
$(o)/%/.staged: $(o)/%/.fetched $(build_files)
	@$(build_stage) $$(readlink $(o)/$*/.versioned) $(platform) $< $@

all_tests := $(foreach x,$(modules),$($(x)_tests))
all_tested := $(patsubst %,o/%.test.ok,$(all_tests))

.PHONY: help
## Show this help message
help: $(build_files) | $(bootstrap_cosmic)
	@$(bootstrap_cosmic) $(o)/bin/make-help.lua $(MAKEFILE_LIST)

.PHONY: test
## Run all tests (incremental)
test: $(o)/test-summary.txt

$(o)/test-summary.txt: $(all_tested) | $(build_reporter)
	@$(reporter) --dir $(o) $^ | tee $@

export TEST_O := $(o)
export TEST_PLATFORM := $(platform)
export TEST_BIN := $(o)/bin
export LUA_PATH := $(CURDIR)/o/bin/?.lua;$(CURDIR)/o/lib/?.lua;$(CURDIR)/o/lib/?/init.lua;$(CURDIR)/lib/?.lua;$(CURDIR)/lib/?/init.lua;;
export NO_COLOR := 1

# test rule
$(o)/%.tl.test.ok: $(o)/%.lua $(test_files) | $(bootstrap_files)
	@mkdir -p $(@D)
	@[ -x $< ] || chmod a+x $<
	-@TEST_DIR=$(TEST_DIR) $(test_runner) $< > $@

# expand test deps
$(foreach m,$(modules),\
  $(eval $(m)_tl_lua := $(patsubst %.tl,$(o)/%.lua,$($(m)_tl_files))))
$(foreach m,$(modules),\
  $(eval $(patsubst %,$(o)/%.test.ok,$($(m)_tests)): $($(m)_files) $($(m)_tl_lua))\
  $(if $($(m)_dir),\
    $(eval $(patsubst %,$(o)/%.test.ok,$($(m)_tests)): $($(m)_dir))\
    $(eval $(patsubst %,$(o)/%.test.ok,$($(m)_tests)): TEST_DIR := $($(m)_dir)))\
  $(foreach d,$($(m)_deps),\
    $(if $($(d)_dir),\
      $(eval $(patsubst %,$(o)/%.test.ok,$($(m)_tests)): $($(d)_dir)))\
    $(eval $(patsubst %,$(o)/%.test.ok,$($(m)_tests)): $($(d)_files) $($(d)_tl_lua))))

.PHONY: clean
## Remove all build artifacts
clean:
	@rm -rf $(o)

.PHONY: bootstrap
## Bootstrap build environment
bootstrap: $(bootstrap_files)

## Run teal type checker on all files
teal: $(o)/teal-summary.txt

all_tl_files := $(foreach x,$(modules),$($(x)_tl_files))
all_teals := $(patsubst %,$(o)/%.teal.ok,$(all_tl_files))

$(o)/teal-summary.txt: $(all_teals) | $(build_reporter)
	@$(reporter) --dir $(o) $^ | tee $@

$(o)/%.tl.teal.ok: %.tl $$(cosmic_bin) $(types_files)
	@mkdir -p $(@D)
	@if TL_PATH='$(TL_PATH)' $(cosmic_bin) --check "$<" >/dev/null 2>$@.err; then \
		echo "pass:" > $@; \
	else \
		n=$$(grep -c ': error:' $@.err 2>/dev/null || echo 0); \
		echo "fail: $$n issues" > $@; \
		echo "" >> $@; echo "## stderr" >> $@; echo "" >> $@; \
		grep ': error:' $@.err >> $@ 2>/dev/null || true; \
	fi; \
	rm -f $@.err

debug-modules:
	@echo $(modules)
