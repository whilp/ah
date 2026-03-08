#!/usr/bin/env cosmic
-- test_cli.tl: tests for CLI display handler and output formatting
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local cli = require("ah.cli")
local events = require("ah.events")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR") or "/tmp"

-- Tool output colorization tests

local function test_colorize_tool_line_pass()
  local result, colored = cli.colorize_tool_line("PASS test_foo")
  assert(colored == true, "PASS should be colored")
  assert(result == "\27[1;34mPASS test_foo\27[0m", "PASS should be blue+bold, got: " .. result)
end
test_colorize_tool_line_pass()

local function test_colorize_tool_line_fail()
  local result, colored = cli.colorize_tool_line("FAIL test_bar")
  assert(colored == true, "FAIL should be colored")
  assert(result == "\27[1;33mFAIL test_bar\27[0m", "FAIL should be yellow+bold, got: " .. result)
end
test_colorize_tool_line_fail()

local function test_colorize_tool_line_error_lower()
  local result, colored = cli.colorize_tool_line("error: something broke")
  assert(colored == true, "error: should be colored")
  assert(result == "\27[1;33merror: something broke\27[0m", "error: should be yellow+bold, got: " .. result)
end
test_colorize_tool_line_error_lower()

local function test_colorize_tool_line_error_upper()
  local result, colored = cli.colorize_tool_line("Error: compilation failed")
  assert(colored == true, "Error: should be colored")
  assert(result == "\27[1;33mError: compilation failed\27[0m", "Error: should be yellow+bold, got: " .. result)
end
test_colorize_tool_line_error_upper()

local function test_colorize_tool_line_exit_code()
  local result, colored = cli.colorize_tool_line("exit code: 1")
  assert(colored == true, "exit code: should be colored")
  assert(result == "\27[1;33mexit code: 1\27[0m", "exit code: should be yellow+bold, got: " .. result)
end
test_colorize_tool_line_exit_code()

local function test_colorize_tool_line_no_match()
  local result, colored = cli.colorize_tool_line("just a normal line")
  assert(colored == false, "normal line should not be colored")
  assert(result == "just a normal line", "normal line should be unchanged, got: " .. result)
end
test_colorize_tool_line_no_match()

local function test_colorize_tool_line_empty()
  local result, colored = cli.colorize_tool_line("")
  assert(colored == false, "empty line should not be colored")
  assert(result == "", "empty line should be unchanged")
end
test_colorize_tool_line_empty()

-- format_tokens tests

local function test_format_tokens()
  assert(cli.format_tokens(0) == "0", "0")
  assert(cli.format_tokens(999) == "999", "999")
  assert(cli.format_tokens(1000) == "1.0k", "1000")
  assert(cli.format_tokens(1200) == "1.2k", "1200")
  assert(cli.format_tokens(1200000) == "1.2m", "1200000")
end
test_format_tokens()

-- make_cli_handler integration tests

local function capture_stderr(fn: function()): string
  local tmpfile = fs.join(TEST_TMPDIR, "test_stderr_" .. tostring(os.time()) .. ".txt")
  local old_stderr = io.stderr
  local new_stderr = io.open(tmpfile, "w")
  io.stderr = new_stderr
  fn()
  io.stderr:close()
  io.stderr = old_stderr
  local output = cio.slurp(tmpfile) or ""
  os.remove(tmpfile)
  return output
end

local function test_make_cli_handler_agent_end_shows_percentage()
  local handler = cli.make_cli_handler(nil)
  local output = capture_stderr(function()
      handler({event_type = "agent_start", model = "claude-opus-4-5-20251101"} as events.EventData)
      handler({
          event_type = "agent_end",
          total_input_tokens = 100000,
          total_output_tokens = 0,
          total_cache_read_tokens = 0,
        } as events.EventData)
    end)
  assert(output:match("%%"), "agent_end output should contain '%', got: " .. output)
  assert(output:match("200%.0k"), "agent_end output should contain '200.0k' budget, got: " .. output)
  assert(output:match("100%.0k"), "agent_end output should contain '100.0k' input, got: " .. output)
end
test_make_cli_handler_agent_end_shows_percentage()

local function test_make_cli_handler_budget_exceeded_shows_percentage()
  local handler = cli.make_cli_handler(nil)
  local output = capture_stderr(function()
      handler({event_type = "agent_start", model = "claude-opus-4-5-20251101"} as events.EventData)
      handler({
          event_type = "budget_exceeded",
          total_input_tokens = 180000,
          total_output_tokens = 10000,
          max_tokens = 200000,
        } as events.EventData)
    end)
  assert(output:match("token budget exceeded"), "should say 'token budget exceeded', got: " .. output)
  assert(output:match("%%"), "budget_exceeded output should contain '%', got: " .. output)
  assert(output:match("190%.0k"), "budget_exceeded output should contain '190.0k' total, got: " .. output)
end
test_make_cli_handler_budget_exceeded_shows_percentage()

local function test_make_cli_handler_agent_end_nil_model_uses_default()
  local handler = cli.make_cli_handler(nil)
  local output = capture_stderr(function()
      handler({
          event_type = "agent_end",
          total_input_tokens = 1000,
          total_output_tokens = 200,
          total_cache_read_tokens = 0,
        } as events.EventData)
    end)
  assert(output:match("200%.0k"), "nil model should fall back to 200.0k budget, got: " .. output)
  assert(output:match("%%"), "output should contain '%', got: " .. output)
end
test_make_cli_handler_agent_end_nil_model_uses_default()

local function test_make_cli_handler_agent_end_no_tokens_no_output()
  local handler = cli.make_cli_handler(nil)
  local output = capture_stderr(function()
      handler({
          event_type = "agent_end",
          total_input_tokens = 0,
          total_output_tokens = 0,
          total_cache_read_tokens = 0,
        } as events.EventData)
    end)
  assert(not output:match("%%"), "zero tokens should produce no token line, got: " .. output)
  assert(not output:match("total"), "zero tokens should produce no total line, got: " .. output)
end
test_make_cli_handler_agent_end_no_tokens_no_output()

-- tool_call_start / tool_call_end output ordering tests

local function test_tool_call_start_bash_single_line()
  local handler = cli.make_cli_handler(nil)
  local output = capture_stderr(function()
      handler({
          event_type = "tool_call_start",
          tool_name = "bash",
          tool_key = "echo hello",
          tool_input = '{"command":"echo hello"}',
          tool_index = 1,
          tool_count = 1,
        } as events.EventData)
    end)
  assert(output:match("%$ echo hello"), "tool_call_start should show $ command, got: " .. output)
  assert(not output:match("%.%ds"), "tool_call_start should not show elapsed time, got: " .. output)
end
test_tool_call_start_bash_single_line()

local function test_tool_call_end_shows_output_then_time()
  local handler = cli.make_cli_handler(nil)
  local output = capture_stderr(function()
      handler({
          event_type = "tool_call_end",
          tool_name = "bash",
          tool_key = "echo hello",
          tool_output = "hello world",
          is_error = false,
          duration_ms = 1500,
          tool_index = 1,
          tool_count = 1,
        } as events.EventData)
    end)
  assert(output:match("hello world"), "tool_call_end should show output, got: " .. output)
  assert(output:match("1%.5s"), "tool_call_end should show elapsed time, got: " .. output)
  assert(output:match("1 line"), "tool_call_end should show line count, got: " .. output)
  assert(not output:match("bash"), "tool_call_end should not repeat tool name, got: " .. output)
  -- Elapsed time should appear after output
  local output_pos = output:find("hello world")
  local time_pos = output:find("1%.5s")
  assert(time_pos > output_pos, "elapsed time should appear after output, got: " .. output)
end
test_tool_call_end_shows_output_then_time()

local function test_tool_call_end_error_shows_exit_code()
  local handler = cli.make_cli_handler(nil)
  -- Error with only "exit code: N" output
  local output = capture_stderr(function()
      handler({
          event_type = "tool_call_end",
          tool_name = "bash",
          tool_key = "false",
          tool_output = "exit code: 1",
          is_error = true,
          duration_ms = 200,
          tool_index = 1,
          tool_count = 1,
        } as events.EventData)
    end)
  assert(output:match("0%.2s"), "should show elapsed time, got: " .. output)
  assert(output:match("exit 1"), "should show exit code in summary, got: " .. output)
  assert(not output:match("✗"), "should not show ✗, got: " .. output)
  assert(not output:match("exit code: 1"), "exit code line should be stripped from preview, got: " .. output)
  -- Error with real output + exit code
  local output2 = capture_stderr(function()
      handler({
          event_type = "tool_call_end",
          tool_name = "bash",
          tool_key = "ls /nonexistent",
          tool_output = "ls: /nonexistent: No such file or directory\nexit code: 2",
          is_error = true,
          duration_ms = 100,
          tool_index = 1,
          tool_count = 1,
        } as events.EventData)
    end)
  assert(output2:match("No such file"), "should show actual error output, got: " .. output2)
  assert(output2:match("exit 2"), "should show exit code in summary, got: " .. output2)
  assert(not output2:match("exit code: 2"), "exit code line should be stripped, got: " .. output2)
end
test_tool_call_end_error_shows_exit_code()

local function test_tool_call_end_bash_line_counts()
  local handler = cli.make_cli_handler(nil)
  -- Multi-line output
  local output = capture_stderr(function()
      handler({
          event_type = "tool_call_end",
          tool_name = "bash",
          tool_key = "ls",
          tool_output = "foo\nbar\nbaz\n",
          is_error = false,
          duration_ms = 100,
          tool_index = 1,
          tool_count = 1,
        } as events.EventData)
    end)
  assert(output:match("3 lines"), "multiline should show '3 lines', got: " .. output)
  -- No output
  local output2 = capture_stderr(function()
      handler({
          event_type = "tool_call_end",
          tool_name = "bash",
          tool_key = "true",
          tool_output = "(no output)",
          is_error = false,
          duration_ms = 50,
          tool_index = 1,
          tool_count = 1,
        } as events.EventData)
    end)
  assert(not output2:match("line"), "no-output should not show line count, got: " .. output2)
end
test_tool_call_end_bash_line_counts()

-- find_difftool tests

local function test_find_difftool_env_var()
  cli.reset_difftool_cache()
  -- Save and set env var
  local old = os.getenv("AH_DIFFTOOL")
  -- We can't unset easily in Lua, but we can use a trick:
  -- set via the C-level isn't available, so just test the logic with a temp var
  -- by checking what happens when we call find_difftool after reset.
  -- The env var test requires the env to be set at test startup via shell.
  -- Skip if AH_DIFFTOOL is not set in the env (can't set env from Lua).
  if old then
    local result = cli.find_difftool()
    assert(result == old, "find_difftool should return AH_DIFFTOOL env var value, got: " .. tostring(result))
  end
  cli.reset_difftool_cache()
end
test_find_difftool_env_var()

local function test_find_difftool_returns_string_or_nil()
  cli.reset_difftool_cache()
  local result = cli.find_difftool()
  assert(result == nil or type(result) == "string", "find_difftool should return string or nil, got: " .. type(result))
  cli.reset_difftool_cache()
end
test_find_difftool_returns_string_or_nil()

local function test_find_difftool_cached()
  cli.reset_difftool_cache()
  local result1 = cli.find_difftool()
  local result2 = cli.find_difftool()
  assert(result1 == result2, "find_difftool should return same cached result")
  cli.reset_difftool_cache()
end
test_find_difftool_cached()

-- run_difftool tests

local function test_run_difftool_invalid_tool()
  local result = cli.run_difftool("/nonexistent/tool/xyz", "- old\n+ new")
  assert(result == nil, "run_difftool with nonexistent tool should return nil, got: " .. tostring(result))
end
test_run_difftool_invalid_tool()

local function test_run_difftool_empty_input()
  local result = cli.run_difftool("cat", "")
  assert(result == nil, "run_difftool with empty input should return nil")
end
test_run_difftool_empty_input()

local function test_run_difftool_nil_tool()
  local result = cli.run_difftool(nil, "- old\n+ new")
  assert(result == nil, "run_difftool with nil tool should return nil")
end
test_run_difftool_nil_tool()

-- DELTA_BASE_ARGS tests

local function test_delta_base_args()
  local function has_arg(name: string): boolean
    for _, arg in ipairs(cli.DELTA_BASE_ARGS) do
      if arg == name then return true end
    end
    return false
  end
  local function has_arg_matching(pattern: string): boolean
    for _, arg in ipairs(cli.DELTA_BASE_ARGS) do
      if arg:match(pattern) then return true end
    end
    return false
  end
  assert(has_arg("--no-gitconfig"), "DELTA_BASE_ARGS should contain --no-gitconfig")
  assert(has_arg("--diff-so-fancy"), "DELTA_BASE_ARGS should contain --diff-so-fancy")
  assert(has_arg("--paging=never"), "DELTA_BASE_ARGS should contain --paging=never")
  assert(has_arg("--syntax-theme=base16"), "DELTA_BASE_ARGS should contain --syntax-theme=base16")
  -- Verify file heading suppression
  assert(has_arg("--file-style=omit"), "DELTA_BASE_ARGS should contain --file-style=omit")
  -- Verify syntax highlighting with background colors
  assert(has_arg_matching("minus%-style"), "DELTA_BASE_ARGS should have minus-style")
  assert(has_arg_matching("plus%-style"), "DELTA_BASE_ARGS should have plus-style")
  -- Verify no green color styles
  for _, arg in ipairs(cli.DELTA_BASE_ARGS) do
    assert(not arg:match("=green"),
      "DELTA_BASE_ARGS should not use green colors: " .. arg)
  end
end
test_delta_base_args()

local function test_run_difftool_with_delta()
  -- If delta is available, verify it processes diff content
  cli.reset_difftool_cache()
  local difftool = cli.find_difftool()
  if difftool then
    local input = "--- a/foo.tl\n+++ b/foo.tl\n@@ -1,1 +1,1 @@\n-old\n+new\n"
    local result = cli.run_difftool(difftool, input)
    assert(result ~= nil, "run_difftool with delta should produce output")
    assert(result:find("old") ~= nil, "delta output should contain 'old', got: " .. tostring(result))
    assert(result:find("new") ~= nil, "delta output should contain 'new', got: " .. tostring(result))
  end
  cli.reset_difftool_cache()
end
test_run_difftool_with_delta()

-- to_unified_diff tests

local function test_to_unified_diff_basic()
  local pseudo = "- old line\n+ new line"
  local result = cli.to_unified_diff(pseudo, "lib/ah/cli.tl")
  assert(result ~= nil, "to_unified_diff should succeed")
  assert(result:find("diff %-%-git a/lib/ah/cli%.tl b/lib/ah/cli%.tl") ~= nil, "should have diff --git header")
  assert(result:find("--- a/lib/ah/cli.tl") ~= nil, "should have --- header")
  assert(result:find("%+%+%+ b/lib/ah/cli.tl") ~= nil, "should have +++ header")
  assert(result:find("@@ %-1,1 %+1,1 @@") ~= nil, "should have @@ hunk header")
  assert(result:find("%-old line") ~= nil, "should have -old line")
  assert(result:find("%+new line") ~= nil, "should have +new line")
end
test_to_unified_diff_basic()

local function test_to_unified_diff_multiline()
  local pseudo = "- old1\n- old2\n+ new1\n+ new2\n+ new3"
  local result = cli.to_unified_diff(pseudo, "foo.tl")
  assert(result ~= nil, "to_unified_diff should succeed with multiline")
  assert(result:find("@@ %-1,2 %+1,3 @@") ~= nil, "should count old/new lines correctly, got: " .. tostring(result))
end
test_to_unified_diff_multiline()

local function test_to_unified_diff_nil_inputs()
  assert(cli.to_unified_diff(nil, "foo.tl") == nil, "nil pseudo_diff should return nil")
  assert(cli.to_unified_diff("", "foo.tl") == nil, "empty pseudo_diff should return nil")
  assert(cli.to_unified_diff("- old\n+ new", nil) == nil, "nil path should return nil")
  assert(cli.to_unified_diff("- old\n+ new", "") == nil, "empty path should return nil")
end
test_to_unified_diff_nil_inputs()

local function test_to_unified_diff_non_diff_input()
  local result = cli.to_unified_diff("edited lib/ah/cli.tl", "lib/ah/cli.tl")
  assert(result == nil, "non-diff input should return nil")
end
test_to_unified_diff_non_diff_input()

local function test_to_unified_diff_roundtrip_with_delta()
  -- run_difftool now always passes base args (--no-gitconfig, etc.), so cat
  -- cannot be used as a mock. test with delta if available; otherwise just
  -- verify to_unified_diff output format.
  local pseudo = "- local y = 2\n+ local y = 42"
  local unified = cli.to_unified_diff(pseudo, "lib/ah/cli.tl")
  assert(unified ~= nil, "should produce unified diff")
  assert(unified:find("%-%-%-") ~= nil, "unified diff should have --- header")
  assert(unified:find("%+%+%+") ~= nil, "unified diff should have +++ header")
  cli.reset_difftool_cache()
  local difftool = cli.find_difftool()
  if difftool then
    local result = cli.run_difftool(difftool, unified)
    assert(result ~= nil, "delta should produce output from unified diff")
    assert(result:find("local y") ~= nil, "delta output should contain diff content")
  end
  cli.reset_difftool_cache()
end
test_to_unified_diff_roundtrip_with_delta()

-- find_pager tests

local function test_find_pager_env_var()
  cli.reset_pager_cache()
  local old = os.getenv("AH_PAGER")
  -- Skip if AH_PAGER is not set in the env (can't set env from Lua)
  if old then
    local result = cli.find_pager()
    assert(result == old, "find_pager should return AH_PAGER env var value, got: " .. tostring(result))
  end
  cli.reset_pager_cache()
end
test_find_pager_env_var()

local function test_find_pager_returns_string_or_nil()
  cli.reset_pager_cache()
  local result = cli.find_pager()
  assert(result == nil or type(result) == "string", "find_pager should return string or nil, got: " .. type(result))
  cli.reset_pager_cache()
end
test_find_pager_returns_string_or_nil()

local function test_find_pager_cached()
  cli.reset_pager_cache()
  local result1 = cli.find_pager()
  local result2 = cli.find_pager()
  assert(result1 == result2, "find_pager should return same cached result")
  cli.reset_pager_cache()
end
test_find_pager_cached()

-- run_pager tests

local function test_run_pager_edge_cases()
  -- cat rejects bat-style flags, so run_pager returns nil
  assert(cli.run_pager("cat", "local x = 1\n", "foo.tl") == nil, "cat should return nil with bat flags")
  assert(cli.run_pager("cat", "", "foo.tl") == nil, "empty content should return nil")
  assert(cli.run_pager(nil, "content", "foo.tl") == nil, "nil pager should return nil")
  assert(cli.run_pager("/nonexistent/tool/xyz", "content", "foo.tl") == nil, "nonexistent tool should return nil")
  assert(cli.run_pager("cat", "content", nil) == nil, "nil file_name should return nil")
  assert(cli.run_pager("cat", "content", "") == nil, "empty file_name should return nil")
end
test_run_pager_edge_cases()

local function test_find_pager_finds_bat()
  cli.reset_pager_cache()
  local unix = require("cosmo.unix")
  local has_bat = unix.commandv("bat")
  if has_bat then
    local result = cli.find_pager()
    assert(result ~= nil and result:find("bat") ~= nil, "find_pager should find bat, got: " .. tostring(result))
  end
  cli.reset_pager_cache()
end
test_find_pager_finds_bat()

local function test_make_cli_handler_agent_end_shows_session_id()
  local fake_ulid = "01ABCDEFGHIJKLMNOPQRSTUVWX"
  local handler = cli.make_cli_handler(nil, fake_ulid)
  local output = capture_stderr(function()
      handler({event_type = "agent_start", model = "claude-opus-4-5-20251101"} as events.EventData)
      handler({
          event_type = "agent_end",
          total_input_tokens = 100000,
          total_output_tokens = 0,
          total_cache_read_tokens = 0,
        } as events.EventData)
    end)
  assert(output:match("%[01ABCDEF%]"), "agent_end output should contain '[01ABCDEF]' short session id, got: " .. output)
end
test_make_cli_handler_agent_end_shows_session_id()

local function test_make_cli_handler_agent_end_no_session_id_when_nil()
  local handler = cli.make_cli_handler(nil, nil)
  local output = capture_stderr(function()
      handler({event_type = "agent_start", model = "claude-opus-4-5-20251101"} as events.EventData)
      handler({
          event_type = "agent_end",
          total_input_tokens = 100000,
          total_output_tokens = 0,
          total_cache_read_tokens = 0,
        } as events.EventData)
    end)
  assert(not output:match("%["), "agent_end output should not contain '[' when session_ulid is nil, got: " .. output)
end
test_make_cli_handler_agent_end_no_session_id_when_nil()

print("all cli tests passed")

-- infer_language tests

local function test_infer_language_extension()
  assert(cli.infer_language("lib/ah/cli.tl") == "Lua", ".tl should map to Lua")
  assert(cli.infer_language("foo.py") == nil, ".py should return nil (not mapped)")
  assert(cli.infer_language("foo.lua") == nil, ".lua should return nil (delta handles natively)")
end
test_infer_language_extension()

local function test_infer_language_shebang()
  assert(cli.infer_language(nil, "#!/usr/bin/env cosmic\nlocal x = 1\n") == "Lua",
    "cosmic shebang should map to Lua")
  assert(cli.infer_language(nil, "#!/usr/local/bin/cosmic\nlocal x = 1\n") == "Lua",
    "direct cosmic shebang should map to Lua")
  assert(cli.infer_language(nil, "#!/usr/bin/env python3\nimport os\n") == nil,
    "python shebang should return nil")
end
test_infer_language_shebang()

local function test_infer_language_extension_takes_precedence()
  assert(cli.infer_language("foo.tl", "#!/usr/bin/env python3\n") == "Lua",
    "extension should take precedence over shebang")
end
test_infer_language_extension_takes_precedence()

local function test_infer_language_nil_inputs()
  assert(cli.infer_language(nil) == nil, "nil path with no content should return nil")
  assert(cli.infer_language(nil, nil) == nil, "nil path and nil content should return nil")
  assert(cli.infer_language("noext") == nil, "no extension should return nil")
end
test_infer_language_nil_inputs()

print("all infer_language tests passed")

-- glow_style tests

local function test_glow_style_returns_string()
  local style = cli.glow_style()
  assert(type(style) == "string", "glow_style should return string, got: " .. type(style))
  -- Should be either a temp file path (extracted from /zip/) or "dark" fallback
  assert(style:match("glow%-style%.json$") or style == "dark",
    "glow_style should return extracted temp path or 'dark', got: " .. style)
  -- If extracted, the file should exist on the real filesystem
  if style ~= "dark" then
    local f = io.open(style, "r")
    assert(f ~= nil, "extracted glow style file should exist at: " .. style)
    if f then f:close() end
  end
end
test_glow_style_returns_string()

local function test_glow_style_cached()
  local s1 = cli.glow_style()
  local s2 = cli.glow_style()
  assert(s1 == s2, "glow_style should return same cached result")
end
test_glow_style_cached()

-- run_glow tests

local function test_run_glow_with_glow()
  cli.reset_glow_cache()
  local glow = cli.find_glow()
  if glow then
    local result = cli.run_glow(glow, "# Hello\n\n- item one\n- item two\n")
    assert(result ~= nil, "run_glow should produce output, got nil")
    -- Strip ANSI escape codes for content matching (glow inserts codes between words)
    local plain = result:gsub("\27%[[%d;]*m", "")
    assert(plain:find("Hello") ~= nil, "glow output should contain 'Hello', got: " .. plain)
    assert(plain:find("item one") ~= nil, "glow output should contain 'item one', got: " .. plain)
  end
  cli.reset_glow_cache()
end
test_run_glow_with_glow()

local function test_run_glow_nil_tool()
  local result = cli.run_glow(nil, "# test")
  assert(result == nil, "run_glow with nil tool should return nil")
end
test_run_glow_nil_tool()

local function test_run_glow_empty_content()
  local result = cli.run_glow("glow", "")
  assert(result == nil, "run_glow with empty content should return nil")
end
test_run_glow_empty_content()

print("all glow tests passed")
