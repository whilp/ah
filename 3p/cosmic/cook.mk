modules += cosmic
cosmic_version := 3p/cosmic/version.lua
cosmic_bin := $(o)/bin/cosmic
cosmic_files := $(cosmic_bin)
cosmic_tests :=

$(cosmic_bin): $$(cosmic_staged)
	@mkdir -p $(@D)
	@cp $(cosmic_dir)/bin/cosmic $@
	@chmod +x $@

cosmic: $(cosmic_bin)

.PHONY: cosmic
