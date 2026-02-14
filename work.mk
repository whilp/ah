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

$(on_branch): $(plan) $(picked_issue)
	@git checkout -b $$(jq -r .branch $(picked_issue)) origin/HEAD
	@touch $@

$(do_done): $(on_branch) $(plan) $(picked_issue) $(AH)
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
		--max-tokens 50000 \
		--unveil $(o)/work/plan:r \
		--unveil $(o)/work/do:r \
		--db $(o)/work/check/session.db \
		< /dev/null
	@touch $@

# fix: run fix agent, push, recheck (called by work-loop)
.PHONY: work-fix
work-fix: $(picked_issue) $(AH)
	@mkdir -p $(o)/work/fix
	@echo "==> fix"
	@timeout 300 $(AH) -n \
		--sandbox \
		--skill fix \
		--max-tokens 100000 \
		--unveil $(o)/work/plan:r \
		--unveil $(o)/work/do:r \
		--db $(o)/work/fix/session.db \
		< $(picked_issue) || true
	@echo "==> push"
	@git push -u origin HEAD
	@rm -f $(check_done)
	@$(MAKE) work-check

$(act_done): $(check_done) $(picked_issue) $(cosmic)
	@mkdir -p $(@D)
	@echo "==> act"
	@$(cosmic) lib/work/act.tl --issue $(picked_issue) \
		--actions $(o)/work/check/actions.json
	@touch $@

# top-level targets
.PHONY: work work-issues work-select work-plan work-do work-push work-check work-fix work-act
work-issues: $(all_issues)
work-select: $(picked_issue)
work-plan: $(plan)
work-do: $(do_done)
work-push: $(push_done)
work-check: $(check_done)
work-act: $(act_done)

# work: full pipeline with fix retries
.PHONY: work
work: $(check_done)
	@for i in 1 2; do \
		v=$$($(cosmic) lib/work/check-verdict.tl --actions $(o)/work/check/actions.json 2>/dev/null || echo unknown); \
		[ "$$v" = "needs-fixes" ] || break; \
		$(MAKE) work-fix; \
	done
	@$(MAKE) $(act_done)
