# bootstrap infrastructure - fetch cosmic for build tools

bootstrap_version := 3p/bootstrap/version.lua
bootstrap_cosmic := $(o)/bootstrap/cosmic
bootstrap_files := $(bootstrap_cosmic)

# build tools from bootstrap cosmic
build_files := $(o)/bin/fetch.lua $(o)/bin/stage.lua $(o)/bin/make-help.lua $(o)/bin/reporter.lua $(o)/bin/run-test.lua
build_fetch := $(bootstrap_cosmic) $(o)/bin/fetch.lua
build_stage := $(bootstrap_cosmic) $(o)/bin/stage.lua
build_reporter := $(o)/bin/reporter.lua
reporter := $(bootstrap_cosmic) $(o)/bin/reporter.lua
test_files := $(o)/bin/run-test.lua
test_runner := $(bootstrap_cosmic) $(o)/bin/run-test.lua

$(bootstrap_cosmic): $(bootstrap_version)
	@mkdir -p $(@D)
	@lua $< $(platform) $@
	@chmod +x $@

$(o)/bin/fetch.lua: lib/build/fetch.tl $(bootstrap_cosmic)
	@mkdir -p $(@D)
	@$(bootstrap_cosmic) --compile $< > $@

$(o)/bin/stage.lua: lib/build/stage.tl $(bootstrap_cosmic)
	@mkdir -p $(@D)
	@$(bootstrap_cosmic) --compile $< > $@

$(o)/bin/make-help.lua: lib/build/make-help.tl $(bootstrap_cosmic)
	@mkdir -p $(@D)
	@$(bootstrap_cosmic) --compile $< > $@

$(o)/bin/reporter.lua: lib/build/reporter.tl $(bootstrap_cosmic)
	@mkdir -p $(@D)
	@$(bootstrap_cosmic) --compile $< > $@

$(o)/bin/run-test.lua: lib/test/run-test.tl $(bootstrap_cosmic)
	@mkdir -p $(@D)
	@$(bootstrap_cosmic) --compile $< > $@
