modules += ah
ah_srcs := $(wildcard lib/ah/*.tl)
ah_tl_files := $(ah_srcs) bin/ah.tl
ah_tests := $(wildcard lib/ah/test_*.tl)
ah_deps := cosmic

ah_tl_lua := $(patsubst lib/%.tl,$(o)/lib/%.lua,$(ah_srcs))
ah_bin := $(o)/bin/ah.lua
ah_files := $(ah_tl_lua) $(ah_bin)
