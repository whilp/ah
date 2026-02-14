# work.mk: work targets
#
# implements the PDCA work loop as make targets:
#   preflight -> issues.json -> issue.json -> plan -> do -> push -> check -> act

REPO ?= whilp/ah
MODEL ?=
MAX_PRS ?= 4
AH := $(o)/bin/ah
PLAN_TIMEOUT := 180
PLAN_MAX_TOKENS := 50000
DO_TIMEOUT := 300
DO_MAX_TOKENS := 100000
CHECK_TIMEOUT := 180
CHECK_MAX_TOKENS := 50000
FIX_TIMEOUT := 300
FIX_MAX_TOKENS := 100000

# ensure labels exist
$(o)/work/labels.ok: $(cosmic)
	@mkdir -p $(@D)
	@$(cosmic) lib/work/ensure-labels.tl $(REPO)
	@touch $@

# check PR limit
$(o)/work/pr-limit.ok: $(cosmic)
	@mkdir -p $(@D)
	@$(cosmic) lib/work/check-pr-limit.tl $(REPO) $(MAX_PRS)
	@touch $@

# fetch open todo issues
$(o)/work/issues.json: $(o)/work/labels.ok $(o)/work/pr-limit.ok $(cosmic)
	@mkdir -p $(@D)
	@$(cosmic) lib/work/issues.tl $(REPO) > $@

# select highest priority issue
$(o)/work/issue.json: $(o)/work/issues.json $(cosmic)
	@mkdir -p $(@D)
	@$(cosmic) lib/work/select.tl < $< > $@

# transition issue to doing
$(o)/work/doing.ok: $(o)/work/issue.json $(cosmic)
	@$(cosmic) lib/work/transition.tl $<
	@touch $@

# build plan prompt from issue
$(o)/work/plan/prompt.txt: $(o)/work/doing.ok $(o)/work/issue.json $(cosmic)
	@mkdir -p $(@D)
	@$(cosmic) lib/work/plan-prompt.tl $(o)/work/issue.json > $@

# run plan agent
$(o)/work/plan/plan.md: $(o)/work/plan/prompt.txt $(AH)
	@mkdir -p $(@D)
	@cp $(o)/work/issue.json $(o)/work/plan/issue.json
	@echo "==> plan"
	@timeout $(PLAN_TIMEOUT) $(AH) -n \
		$(if $(MODEL),-m $(MODEL)) \
		--max-tokens $(PLAN_MAX_TOKENS) \
		--db $(o)/work/plan/session.db \
		< $< || true
	@test -s $@ || (echo "error: plan.md not created" >&2; exit 1)

# build do prompt from plan
$(o)/work/do/prompt.txt: $(o)/work/plan/plan.md $(o)/work/issue.json $(cosmic)
	@mkdir -p $(@D)
	@$(cosmic) lib/work/do-prompt.tl $(o)/work/issue.json $< > $@

# extract branch name
$(o)/work/do/branch.txt: $(o)/work/plan/plan.md $(o)/work/issue.json $(cosmic)
	@mkdir -p $(@D)
	@$(cosmic) lib/work/extract-branch.tl $< $(o)/work/issue.json > $@

# run do agent
$(o)/work/do/done: $(o)/work/do/prompt.txt $(o)/work/do/branch.txt $(AH)
	@echo "==> do"
	@timeout $(DO_TIMEOUT) $(AH) -n \
		$(if $(MODEL),-m $(MODEL)) \
		--max-tokens $(DO_MAX_TOKENS) \
		--unveil $(o)/work/plan:r \
		--db $(o)/work/do/session.db \
		< $< || true
	@touch $@

# push work branch
$(o)/work/push/done: $(o)/work/do/done $(o)/work/do/branch.txt
	@mkdir -p $(@D)
	@echo "==> push"
	@$(cosmic) lib/work/push.tl $(o)/work/do/branch.txt
	@touch $@

# build check prompt
$(o)/work/check/prompt.txt: $(o)/work/push/done $(o)/work/plan/plan.md $(cosmic)
	@mkdir -p $(@D)
	@$(cosmic) lib/work/check-prompt.tl $(o)/work/plan/plan.md $(o)/work/do/do.md > $@

# run check agent
$(o)/work/check/done: $(o)/work/check/prompt.txt $(AH)
	@echo "==> check"
	@timeout $(CHECK_TIMEOUT) $(AH) -n \
		$(if $(MODEL),-m $(MODEL)) \
		--max-tokens $(CHECK_MAX_TOKENS) \
		--unveil $(o)/work/plan:r \
		--unveil $(o)/work/do:r \
		--db $(o)/work/check/session.db \
		< $<
	@touch $@

# fix loop: retry fix/push/check if verdict is needs-fixes
$(o)/work/fix/done: $(o)/work/check/done $(cosmic)
	@mkdir -p $(@D)
	@bash lib/work/fix-loop.sh $(cosmic) $(AH) "$(MODEL)" 2
	@touch $@

# run act phase (deterministic, no agent)
$(o)/work/act/done: $(o)/work/fix/done $(o)/work/issue.json $(cosmic)
	@mkdir -p $(@D)
	@echo "==> act"
	@$(cosmic) lib/work/act.tl $(o)/work/issue.json $(o)/work/check/actions.json \
		$(o)/work/do/branch.txt
	@touch $@

# top-level work target
.PHONY: work
work: $(o)/work/act/done

.PHONY: work-issues
work-issues: $(o)/work/issues.json

.PHONY: work-select
work-select: $(o)/work/issue.json

.PHONY: work-plan
work-plan: $(o)/work/plan/plan.md

.PHONY: work-do
work-do: $(o)/work/do/done

.PHONY: work-push
work-push: $(o)/work/push/done

.PHONY: work-check
work-check: $(o)/work/check/done

.PHONY: work-act
work-act: $(o)/work/act/done
