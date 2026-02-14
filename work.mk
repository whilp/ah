# work.mk: work targets
#
# implements the PDCA work loop as make targets:
#   issues.json -> issue.json -> plan -> do -> push -> check -> fix -> act

REPO ?= whilp/ah

# fetch open todo issues
$(o)/work/issues.json: $(cosmic)
	@mkdir -p $(@D)
	@$(cosmic) lib/work/issues.tl $(REPO) > $@

# select highest priority issue
$(o)/work/issue.json: $(o)/work/issues.json $(cosmic)
	@mkdir -p $(@D)
	@$(cosmic) lib/work/select.tl < $< > $@

.PHONY: work-issues
work-issues: $(o)/work/issues.json

.PHONY: work-select
work-select: $(o)/work/issue.json
