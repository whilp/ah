# work.mk: work targets
#
# implements the PDCA work loop as make targets:
#   preflight -> issues.json -> issue.json -> plan -> do -> push -> check -> act
#
# convention: pipeline scripts in lib/work/ read env vars (WORK_*) instead
# of CLI args. pattern rules provide recipes; dependency-only rules add
# per-target prerequisites.
#
# convergence: check writes o/work/do/feedback.md when verdict is needs-fixes.
# since do depends on feedback.md, the next make run re-executes do -> push -> check.
# the caller runs `make work` which loops until convergence or a retry limit.

REPO ?= whilp/ah
MAX_PRS ?= 4
AH := $(o)/bin/ah

# detect the remote default branch
# in CI: DEFAULT_BRANCH is set by the workflow from github.event.repository.default_branch
# locally: fall back to git symbolic-ref, then origin/main
DEFAULT_BRANCH ?= $(shell git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/||')
DEFAULT_BRANCH := $(or $(DEFAULT_BRANCH),origin/main)

# shared env vars for all work scripts
export WORK_REPO := $(REPO)
export WORK_MAX_PRS := $(MAX_PRS)
export WORK_DEFAULT_BRANCH := $(DEFAULT_BRANCH)
export WORK_INPUT := $(o)/work/issues.json
export WORK_ISSUE := $(o)/work/issue.json

# named targets
all_issues := $(o)/work/issues.json
picked_issue := $(o)/work/issue.json
is_doing := $(o)/work/doing.ok
plan := $(o)/work/plan/plan.md
feedback := $(o)/work/do/feedback.md
on_branch := $(o)/work/branch.ok
do_done := $(o)/work/do/done
push_done := $(o)/work/push/done
check_done := $(o)/work/check/done
act_done := $(o)/work/act/done

.DELETE_ON_ERROR:

# pattern: run lib/work/%.tl, capture stdout to output file
$(o)/work/%.json: lib/work/%.tl $(cosmic)
	@mkdir -p $(@D)
	@$(cosmic) $< > $@

$(o)/work/%.ok: lib/work/%.tl $(cosmic)
	@mkdir -p $(@D)
	@$(cosmic) $< > $@

# --- per-target dependencies (no recipes) ---

$(all_issues): $(o)/work/labels.ok $(o)/work/pr-limit.ok
$(picked_issue): $(all_issues)
$(is_doing): $(picked_issue)

# --- agent targets ---

$(plan): $(is_doing) $(picked_issue) $(AH)
	@mkdir -p $(@D)
	@cp $(picked_issue) $(o)/work/plan/issue.json
	@echo "==> plan"
	@timeout 180 $(AH) -n \
		--sandbox \
		--skill plan \
		--must-produce $@ \
		--max-tokens 50000 \
		--db $(o)/work/plan/session.db \
		< $(picked_issue)

# feedback.md: created empty after plan, updated by check agent.
# exists as an explicit target so make can resolve the dependency from do_done.
$(feedback): $(plan)
	@mkdir -p $(@D)
	@touch $@

$(on_branch): $(plan) $(picked_issue)
	@git checkout -b $$(jq -r .branch $(picked_issue)) $(DEFAULT_BRANCH)
	@touch $@

$(do_done): $(on_branch) $(plan) $(feedback) $(picked_issue) $(AH)
	@mkdir -p $(@D)
	@echo "==> do"
	@timeout 300 $(AH) -n \
		--sandbox \
		--skill do \
		--max-tokens 100000 \
		--unveil $(o)/work/plan:r \
		--db $(o)/work/do/session.db \
		< $(picked_issue)
	@touch $@

$(push_done): $(do_done)
	@mkdir -p $(@D)
	@echo "==> push"
	@git push -u origin HEAD
	@touch $@

$(check_done): $(push_done) $(plan) $(AH)
	@mkdir -p $(@D)
	@echo "==> check"
	@timeout 180 $(AH) -n \
		--sandbox \
		--skill check \
		--must-produce $(o)/work/check/actions.json \
		--max-tokens 50000 \
		--unveil $(o)/work/plan:r \
		--unveil $(o)/work/do:r \
		--db $(o)/work/check/session.db \
		< /dev/null
	@touch $@

$(act_done): $(check_done) $(picked_issue) $(cosmic)
	@mkdir -p $(@D)
	@echo "==> act"
	@$(cosmic) lib/work/act.tl --issue $(picked_issue) \
		--actions $(o)/work/check/actions.json
	@touch $@

# work: converge on check, then act.
# check agent writes feedback.md when verdict is needs-fixes, which makes
# do_done stale so the next make re-runs do -> push -> check.
# once converged, make check is a no-op.
.PHONY: work
work:
	@$(MAKE) $(check_done)
	@$(MAKE) $(check_done)
	@$(MAKE) $(check_done)
	@$(MAKE) $(act_done)
