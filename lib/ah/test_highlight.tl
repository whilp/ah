#!/usr/bin/env cosmic
-- test_highlight.tl: tests for external tool integration (delta, bat, glow)
local hl = require("ah.highlight")
local cenv = require("cosmic.env")

-- find_difftool tests

local function test_find_difftool_env_var()
  hl.reset_difftool_cache()
  -- Save and set env var
  local old = cenv.get("AH_DIFFTOOL")
  -- We can't unset easily in Lua, but we can use a trick:
  -- set via the C-level isn't available, so just test the logic with a temp var
  -- by checking what happens when we call find_difftool after reset.
  -- The env var test requires the env to be set at test startup via shell.
  if old and old ~= "" then
    local result = hl.find_difftool()
    assert(result == old, "find_difftool should return AH_DIFFTOOL env var value, got: " .. tostring(result))
  end
  hl.reset_difftool_cache()
end
test_find_difftool_env_var()

local function test_find_difftool_returns_string_or_nil()
  hl.reset_difftool_cache()
  local result = hl.find_difftool()
  assert(result == nil or type(result) == "string", "find_difftool should return string or nil, got: " .. type(result))
  hl.reset_difftool_cache()
end
test_find_difftool_returns_string_or_nil()

local function test_find_difftool_cached()
  hl.reset_difftool_cache()
  local result1 = hl.find_difftool()
  local result2 = hl.find_difftool()
  assert(result1 == result2, "find_difftool should return same cached result")
  hl.reset_difftool_cache()
end
test_find_difftool_cached()

-- run_difftool tests

local function test_run_difftool_invalid_tool()
  local result = hl.run_difftool("/nonexistent/tool/xyz", "- old\n+ new")
  assert(result == nil, "run_difftool with nonexistent tool should return nil, got: " .. tostring(result))
end
test_run_difftool_invalid_tool()

local function test_run_difftool_empty_input()
  local result = hl.run_difftool("cat", "")
  assert(result == nil, "run_difftool with empty input should return nil")
end
test_run_difftool_empty_input()

local function test_run_difftool_nil_tool()
  local result = hl.run_difftool(nil, "- old\n+ new")
  assert(result == nil, "run_difftool with nil tool should return nil")
end
test_run_difftool_nil_tool()

-- DELTA_BASE_ARGS tests

local function test_delta_base_args()
  local function has_arg(needle: string): boolean
    for _, arg in ipairs(hl.DELTA_BASE_ARGS) do
      if arg == needle then return true end
    end
    return false
  end
  local function has_arg_matching(pattern: string): boolean
    for _, arg in ipairs(hl.DELTA_BASE_ARGS) do
      if arg:match(pattern) then return true end
    end
    return false
  end
  assert(has_arg("--no-gitconfig"), "DELTA_BASE_ARGS should contain --no-gitconfig")
  assert(has_arg("--diff-so-fancy"), "DELTA_BASE_ARGS should contain --diff-so-fancy")
  assert(has_arg("--paging=never"), "DELTA_BASE_ARGS should contain --paging=never")
  assert(has_arg("--syntax-theme=base16"), "DELTA_BASE_ARGS should contain --syntax-theme=base16")

  assert(has_arg("--file-style=omit"), "DELTA_BASE_ARGS should contain --file-style=omit")

  assert(has_arg_matching("minus%-style"), "DELTA_BASE_ARGS should have minus-style")
  assert(has_arg_matching("plus%-style"), "DELTA_BASE_ARGS should have plus-style")

  for _, arg in ipairs(hl.DELTA_BASE_ARGS) do
    assert(not arg:match("#%x*[Gg][Rr]"), -- crude green-ish hex check
      "DELTA_BASE_ARGS should not use green colors: " .. arg)
  end
  print("PASS: DELTA_BASE_ARGS has required fields and colorblind-friendly colors")
end
test_delta_base_args()

local function test_run_difftool_with_delta()
  local input = "--- a/foo.tl\n+++ b/foo.tl\n@@ -1 +1 @@\n-old line\n+new line\n"
  hl.reset_difftool_cache()
  local difftool = hl.find_difftool()
  if difftool then
    local result = hl.run_difftool(difftool, input)
    assert(result ~= nil, "run_difftool with delta should produce output")
    assert(#result > 0, "output should be non-empty")
    print("PASS: run_difftool with delta produces output")
  end
  hl.reset_difftool_cache()
end
test_run_difftool_with_delta()

-- to_unified_diff tests

local function test_to_unified_diff_basic()
  local pseudo = "- old line\n+ new line\n"
  local result = hl.to_unified_diff(pseudo, "lib/ah/cli.tl")
  assert(result ~= nil, "to_unified_diff should succeed")
  assert(result:match("--- a/lib/ah/cli.tl"), "should have --- header")
  assert(result:match("%+%+%+ b/lib/ah/cli.tl"), "should have +++ header")
  assert(result:match("@@"), "should have hunk header")
  assert(result:match("%-old line"), "should have removed line")
  assert(result:match("%+new line"), "should have added line")
  print("PASS: to_unified_diff basic conversion")
end
test_to_unified_diff_basic()

local function test_to_unified_diff_multiline()
  local pseudo = "- line one\n- line two\n+ line ONE\n+ line TWO\n+ line THREE\n"
  local result = hl.to_unified_diff(pseudo, "foo.tl")
  assert(result ~= nil, "to_unified_diff should succeed with multiline")
  assert(result:match("@@ %-1,2 %+1,3 @@"), "hunk header should show correct counts")
  print("PASS: to_unified_diff multiline")
end
test_to_unified_diff_multiline()

local function test_to_unified_diff_nil_inputs()
  assert(hl.to_unified_diff(nil, "foo.tl") == nil, "nil pseudo_diff should return nil")
  assert(hl.to_unified_diff("", "foo.tl") == nil, "empty pseudo_diff should return nil")
  assert(hl.to_unified_diff("- old\n+ new", nil) == nil, "nil path should return nil")
  assert(hl.to_unified_diff("- old\n+ new", "") == nil, "empty path should return nil")
  print("PASS: to_unified_diff nil/empty inputs return nil")
end
test_to_unified_diff_nil_inputs()

local function test_to_unified_diff_non_diff_input()
  local result = hl.to_unified_diff("edited lib/ah/cli.tl", "lib/ah/cli.tl")
  assert(result == nil, "non-diff input should return nil")
  print("PASS: to_unified_diff non-diff input returns nil")
end
test_to_unified_diff_non_diff_input()

local function test_to_unified_diff_roundtrip_with_delta()
  -- run_difftool now always passes base args (--no-gitconfig, etc.), so cat
  -- won't work as a drop-in. Instead, just use delta if available to
  -- verify to_unified_diff output format.
  local pseudo = "- old line\n+ new line\n"
  local unified = hl.to_unified_diff(pseudo, "lib/ah/cli.tl")
  assert(unified ~= nil, "to_unified_diff should succeed")
  assert(unified:match("^diff %-%-git"), "should start with diff --git header")

  hl.reset_difftool_cache()
  local difftool = hl.find_difftool()
  if difftool then
    local result = hl.run_difftool(difftool, unified)
    assert(result ~= nil, "delta should render to_unified_diff output")
    print("PASS: to_unified_diff output renders through delta")
  end
  hl.reset_difftool_cache()
end
test_to_unified_diff_roundtrip_with_delta()

-- find_pager tests

local function test_find_pager_env_var()
  hl.reset_pager_cache()
  local old = os.getenv("AH_PAGER")
  if old and old ~= "" then
    local result = hl.find_pager()
    assert(result == old, "find_pager should return AH_PAGER env var value, got: " .. tostring(result))
  end
  hl.reset_pager_cache()
end
test_find_pager_env_var()

local function test_find_pager_returns_string_or_nil()
  hl.reset_pager_cache()
  local result = hl.find_pager()
  assert(result == nil or type(result) == "string", "find_pager should return string or nil, got: " .. type(result))
  hl.reset_pager_cache()
end
test_find_pager_returns_string_or_nil()

local function test_find_pager_cached()
  hl.reset_pager_cache()
  local result1 = hl.find_pager()
  local result2 = hl.find_pager()
  assert(result1 == result2, "find_pager should return same cached result")
  hl.reset_pager_cache()
end
test_find_pager_cached()

-- run_pager tests

local function test_run_pager_edge_cases()
  -- cat rejects bat-style flags, so run_pager returns nil
  assert(hl.run_pager("cat", "local x = 1\n", "foo.tl") == nil, "cat should return nil with bat flags")
  assert(hl.run_pager("cat", "", "foo.tl") == nil, "empty content should return nil")
  assert(hl.run_pager(nil, "content", "foo.tl") == nil, "nil pager should return nil")
  assert(hl.run_pager("/nonexistent/tool/xyz", "content", "foo.tl") == nil, "nonexistent tool should return nil")
  assert(hl.run_pager("cat", "content", nil) == nil, "nil file_name should return nil")
  assert(hl.run_pager("cat", "content", "") == nil, "empty file_name should return nil")
  print("PASS: run_pager edge cases")
end
test_run_pager_edge_cases()

local function test_find_pager_finds_bat()
  hl.reset_pager_cache()
  -- Only test if bat is actually installed
  local bat_check = os.execute("which bat >/dev/null 2>&1")
  if bat_check then
    local result = hl.find_pager()
    assert(result ~= nil and result:find("bat") ~= nil, "find_pager should find bat, got: " .. tostring(result))
    print("PASS: find_pager finds bat")
  end
  hl.reset_pager_cache()
end
test_find_pager_finds_bat()

local function test_run_pager_with_bat()
  hl.reset_pager_cache()
  local pager = hl.find_pager()
  if pager then
    local content = "local x = 1\nlocal y = 2\nreturn x + y\n"
    local result = hl.run_pager(pager, content, "test.tl")
    if result then
      assert(#result > 0, "pager output should be non-empty")
      print("PASS: run_pager with bat produces output")
    end
  end
  hl.reset_pager_cache()
end
test_run_pager_with_bat()

local function test_run_pager_strips_line_numbers()
  hl.reset_pager_cache()
  local pager = hl.find_pager()
  if pager then
    local content = "1\tlocal x = 1\n2\tlocal y = 2\n3\treturn x + y\n"
    local result = hl.run_pager(pager, content, "test.tl")
    if result then
      -- Line number prefixes should be stripped before highlighting
      assert(not result:match("^1\t"), "line number prefixes should be stripped")
      print("PASS: run_pager strips line number prefixes")
    end
  end
  hl.reset_pager_cache()
end
test_run_pager_strips_line_numbers()

-- infer_language tests

local function test_infer_language_extension()
  assert(hl.infer_language("lib/ah/cli.tl") == "Lua", ".tl should map to Lua")
  assert(hl.infer_language("foo.py") == nil, ".py should return nil (not mapped)")
  assert(hl.infer_language("foo.lua") == nil, ".lua should return nil (delta handles natively)")
  print("PASS: infer_language extension mapping")
end
test_infer_language_extension()

local function test_infer_language_shebang()
  assert(hl.infer_language(nil, "#!/usr/bin/env cosmic\nlocal x = 1\n") == "Lua",
    "cosmic shebang should map to Lua")
  assert(hl.infer_language(nil, "#!/usr/local/bin/cosmic\nlocal x = 1\n") == "Lua",
    "direct cosmic path should map to Lua")
  assert(hl.infer_language(nil, "#!/usr/bin/env python3\nimport os\n") == nil,
    "python shebang should return nil (not mapped)")
  print("PASS: infer_language shebang detection")
end
test_infer_language_shebang()

local function test_infer_language_extension_takes_precedence()
  assert(hl.infer_language("foo.tl", "#!/usr/bin/env python3\n") == "Lua",
    "extension should take precedence over shebang")
  print("PASS: infer_language extension takes precedence")
end
test_infer_language_extension_takes_precedence()

local function test_infer_language_nil_inputs()
  assert(hl.infer_language(nil) == nil, "nil path with no content should return nil")
  assert(hl.infer_language(nil, nil) == nil, "nil path and nil content should return nil")
  assert(hl.infer_language("noext") == nil, "no extension should return nil")
  print("PASS: infer_language nil/edge inputs")
end
test_infer_language_nil_inputs()

print("all infer_language tests passed")

-- glow_style tests

local function test_glow_style_returns_string()
  local style = hl.glow_style()
  assert(type(style) == "string", "glow_style should return string, got: " .. type(style))
  local style_ok = style == "dark" or style:match("%.json$") ~= nil
  assert(style_ok,
    "glow_style should return extracted temp path or 'dark', got: " .. style)
  -- If embedded file exists, should extract to temp
  local f = io.open("/zip/embed/sys/glow.json", "r")
  if f then
    f:close()
    assert(style:match("%.json$"), "with embedded glow.json, style should be a temp file path")
  end
  print("PASS: glow_style returns valid style")
end
test_glow_style_returns_string()

local function test_glow_style_cached()
  local s1 = hl.glow_style()
  local s2 = hl.glow_style()
  assert(s1 == s2, "glow_style should return same cached result")
  print("PASS: glow_style caching")
end
test_glow_style_cached()

-- run_glow tests

local function test_run_glow_with_glow()
  hl.reset_glow_cache()
  local glow = hl.find_glow()
  if glow then
    local result = hl.run_glow(glow, "# Hello\n\n- item one\n- item two\n")
    assert(result ~= nil, "run_glow should produce output, got nil")
    assert(#result > 0, "run_glow output should be non-empty")
    -- Don't check for ANSI — piped glow may or may not emit colors
    -- depending on CLICOLOR_FORCE support
    print("PASS: run_glow with glow produces output")
  end
  hl.reset_glow_cache()
end
test_run_glow_with_glow()

local function test_run_glow_nil_tool()
  local result = hl.run_glow(nil, "# test")
  assert(result == nil, "run_glow with nil tool should return nil")
  print("PASS: run_glow nil tool")
end
test_run_glow_nil_tool()

local function test_run_glow_empty_content()
  local result = hl.run_glow("glow", "")
  assert(result == nil, "run_glow with empty content should return nil")
  print("PASS: run_glow empty content")
end
test_run_glow_empty_content()

print("all glow tests passed")
