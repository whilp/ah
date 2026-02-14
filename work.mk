# work.mk: work targets
#
# implements the PDCA work loop as make targets:
#   preflight -> issues.json -> issue.json -> plan -> do -> push -> check -> act
#
# convention: pipeline scripts in lib/work/ read env vars (WORK_*) instead
# of CLI args. pattern rules provide recipes; dependency-only rules add
# per-target prerequisites.

REPO ?= whilp/ah
MODEL ?=
MAX_PRS ?= 4
AH := $(o)/bin/ah
render = $(cosmic) lib/work/render.tl
PLAN_TIMEOUT := 180
PLAN_MAX_TOKENS := 50000
DO_TIMEOUT := 300
DO_MAX_TOKENS := 100000
CHECK_TIMEOUT := 180
CHECK_MAX_TOKENS := 50000
FIX_TIMEOUT := 300
FIX_MAX_TOKENS := 100000

# shared env vars for all work scripts
export WORK_REPO := $(REPO)
export WORK_MAX_PRS := $(MAX_PRS)
export WORK_O := $(o)/work

.DELETE_ON_ERROR:

# pattern: run lib/work/%.tl, capture stdout to output file
$(o)/work/%.json: lib/work/%.tl $(cosmic)
	@mkdir -p $(@D)
	@$(cosmic) $< > $@

$(o)/work/%.ok: lib/work/%.tl $(cosmic)
	@mkdir -p $(@D)
	@$(cosmic) $< > $@

$(o)/work/%.txt: lib/work/%.tl $(cosmic)
	@mkdir -p $(@D)
	@$(cosmic) $< > $@

# --- per-target dependencies (no recipes) ---

$(o)/work/issues.json: $(o)/work/labels.ok $(o)/work/pr-limit.ok

$(o)/work/issue.json: $(o)/work/issues.json
# export WORK_INPUT so issue.tl finds its input
$(o)/work/issue.json: export WORK_INPUT = $(o)/work/issues.json

$(o)/work/doing.ok: $(o)/work/issue.json
$(o)/work/doing.ok: export WORK_ISSUE = $(o)/work/issue.json

# --- prompt and agent targets (don't fit pattern) ---

# build plan prompt from issue
$(o)/work/plan/prompt.txt: $(o)/work/doing.ok $(o)/work/issue.json $(cosmic)
	@mkdir -p $(@D)
	@$(render) --template sys/skills/plan.md \
		--json-vars $(o)/work/issue.json \
		--var issue_number=$$($(cosmic) lib/work/jq.tl --file $(o)/work/issue.json --field number) \
		> $@

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

# extract branch name
$(o)/work/do/branch.txt: $(o)/work/plan/plan.md $(o)/work/issue.json $(cosmic)
	@mkdir -p $(@D)
	@$(cosmic) lib/work/extract-branch.tl --plan $< --issue $(o)/work/issue.json > $@

# build do prompt from plan
$(o)/work/do/prompt.txt: $(o)/work/plan/plan.md $(o)/work/do/branch.txt $(o)/work/issue.json $(cosmic)
	@mkdir -p $(@D)
	@$(render) --template sys/skills/do.md \
		--json-vars $(o)/work/issue.json \
		--var-file "plan.md contents"=$(o)/work/plan/plan.md \
		--var branch=$$(cat $(o)/work/do/branch.txt) \
		> $@

# run do agent
$(o)/work/do/done: $(o)/work/do/prompt.txt $(AH)
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
	@$(cosmic) lib/work/push.tl --branch-file $(o)/work/do/branch.txt
	@touch $@

# build check prompt
$(o)/work/check/prompt.txt: $(o)/work/push/done $(o)/work/plan/plan.md $(cosmic)
	@mkdir -p $(@D)
	@$(render) --template sys/skills/check.md \
		--var-file "plan.md contents"=$(o)/work/plan/plan.md \
		--var-file "do.md contents"=$(o)/work/do/do.md \
		> $@

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
	@$(cosmic) lib/work/act.tl --issue $(o)/work/issue.json \
		--actions $(o)/work/check/actions.json
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
