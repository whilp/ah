# work.mk: work targets
#
# implements the PDCA work loop as make targets:
#   preflight -> issues.json -> issue.json -> plan -> do -> push -> check -> act
#
# convention: pipeline scripts in lib/work/ read env vars (WORK_*) instead
# of CLI args. pattern rules provide recipes; dependency-only rules add
# per-target prerequisites.

REPO ?= whilp/ah
MAX_PRS ?= 4
AH := $(o)/bin/ah
PLAN_TIMEOUT := 180
PLAN_MAX_TOKENS := 50000
DO_TIMEOUT := 300
DO_MAX_TOKENS := 100000
CHECK_TIMEOUT := 180
CHECK_MAX_TOKENS := 50000

# shared env vars for all work scripts
export WORK_REPO := $(REPO)
export WORK_MAX_PRS := $(MAX_PRS)
export WORK_INPUT := $(o)/work/issues.json
export WORK_ISSUE := $(o)/work/issue.json

# named targets
all_issues := $(o)/work/issues.json
picked_issue := $(o)/work/issue.json
is_doing := $(o)/work/doing.ok
plan := $(o)/work/plan/plan.md
do_done := $(o)/work/do/done
push_done := $(o)/work/push/done
check_done := $(o)/work/check/done
fix_done := $(o)/work/fix/done
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
	@timeout $(PLAN_TIMEOUT) $(AH) -n \
		--skill plan \
		--max-tokens $(PLAN_MAX_TOKENS) \
		--db $(o)/work/plan/session.db \
		< $(picked_issue)
	@test -s $@ || (echo "error: plan.md not created" >&2; exit 1)

$(do_done): $(plan) $(picked_issue) $(AH)
	@mkdir -p $(@D)
	@echo "==> do"
	@timeout $(DO_TIMEOUT) $(AH) -n \
		--skill do \
		--max-tokens $(DO_MAX_TOKENS) \
		--unveil $(o)/work/plan:r \
		--db $(o)/work/do/session.db \
		< $(picked_issue)
	@touch $@

$(push_done): $(do_done) $(picked_issue) $(cosmic)
	@mkdir -p $(@D)
	@echo "==> push"
	@$(cosmic) lib/work/push.tl
	@touch $@

$(check_done): $(push_done) $(plan) $(AH)
	@mkdir -p $(@D)
	@echo "==> check"
	@timeout $(CHECK_TIMEOUT) $(AH) -n \
		--skill check \
		--max-tokens $(CHECK_MAX_TOKENS) \
		--unveil $(o)/work/plan:r \
		--unveil $(o)/work/do:r \
		--db $(o)/work/check/session.db \
		< /dev/null
	@touch $@

$(fix_done): $(check_done) $(cosmic)
	@mkdir -p $(@D)
	@bash lib/work/fix-loop.sh $(cosmic) $(AH) 2
	@touch $@

$(act_done): $(fix_done) $(picked_issue) $(cosmic)
	@mkdir -p $(@D)
	@echo "==> act"
	@$(cosmic) lib/work/act.tl --issue $(picked_issue) \
		--actions $(o)/work/check/actions.json
	@touch $@

# top-level targets
.PHONY: work work-issues work-select work-plan work-do work-push work-check work-act
work: $(act_done)
work-issues: $(all_issues)
work-select: $(picked_issue)
work-plan: $(plan)
work-do: $(do_done)
work-push: $(push_done)
work-check: $(check_done)
work-act: $(act_done)
