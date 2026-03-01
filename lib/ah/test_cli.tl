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

local function test_format_tokens_zero()
  local result = cli.format_tokens(0)
  assert(result == "0", "0 should format as '0', got: " .. result)
end
test_format_tokens_zero()

local function test_format_tokens_small()
  local result = cli.format_tokens(999)
  assert(result == "999", "999 should format as '999', got: " .. result)
end
test_format_tokens_small()

local function test_format_tokens_exact_thousand()
  local result = cli.format_tokens(1000)
  assert(result == "1.0k", "1000 should format as '1.0k', got: " .. result)
end
test_format_tokens_exact_thousand()

local function test_format_tokens_thousands()
  local result = cli.format_tokens(1200)
  assert(result == "1.2k", "1200 should format as '1.2k', got: " .. result)
end
test_format_tokens_thousands()

local function test_format_tokens_millions()
  local result = cli.format_tokens(1200000)
  assert(result == "1.2m", "1200000 should format as '1.2m', got: " .. result)
end
test_format_tokens_millions()

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

local function test_tool_call_start_shows_name_and_command()
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
  assert(output:match("bash"), "tool_call_start should show tool name, got: " .. output)
  assert(output:match("echo hello"), "tool_call_start should show command, got: " .. output)
  assert(not output:match("%.%ds"), "tool_call_start should not show elapsed time, got: " .. output)
end
test_tool_call_start_shows_name_and_command()

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
  assert(not output:match("bash"), "tool_call_end should not repeat tool name, got: " .. output)
  -- Elapsed time should appear after output
  local output_pos = output:find("hello world")
  local time_pos = output:find("1%.5s")
  assert(time_pos > output_pos, "elapsed time should appear after output, got: " .. output)
end
test_tool_call_end_shows_output_then_time()

local function test_tool_call_end_error_shows_marker()
  local handler = cli.make_cli_handler(nil)
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
  assert(output:match("0%.2s"), "error tool_call_end should show elapsed time, got: " .. output)
end
test_tool_call_end_error_shows_marker()

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

local function test_run_difftool_cat_passthrough()
  local input = "- old line\n+ new line"
  local result = cli.run_difftool("cat", input)
  assert(result ~= nil, "run_difftool with cat should succeed")
  assert(result:find("old line") ~= nil, "output should contain input text, got: " .. tostring(result))
end
test_run_difftool_cat_passthrough()

local function test_run_difftool_preserves_multiline_diff()
  local input = "--- a/foo.tl\n+++ b/foo.tl\n@@ -1,3 +1,3 @@\n line1\n-old\n+new\n line3\n"
  local result = cli.run_difftool("cat", input)
  assert(result ~= nil, "run_difftool should succeed with multiline diff")
  assert(result == input, "run_difftool should preserve diff content exactly, got: " .. tostring(result))
end
test_run_difftool_preserves_multiline_diff()

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

-- to_unified_diff tests

local function test_to_unified_diff_basic()
  local pseudo = "- old line\n+ new line"
  local result = cli.to_unified_diff(pseudo, "lib/ah/cli.tl")
  assert(result ~= nil, "to_unified_diff should succeed")
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

local function test_to_unified_diff_roundtrip_with_cat()
  local pseudo = "- local y = 2\n+ local y = 42"
  local unified = cli.to_unified_diff(pseudo, "lib/ah/cli.tl")
  assert(unified ~= nil, "should produce unified diff")
  local result = cli.run_difftool("cat", unified)
  assert(result ~= nil, "cat should succeed")
  assert(result == unified, "cat roundtrip should preserve content exactly")
end
test_to_unified_diff_roundtrip_with_cat()

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

local function test_run_pager_cat_passthrough()
  local content = "local x = 1\nlocal y = 2\n"
  -- Use 'cat' but with a wrapper that drops extra args and reads from stdin via redirection
  -- run_pager passes content via temp file as stdin redirect, so test with a cat-like command
  -- that ignores the --file-name/--color/--style flags (not available in plain cat).
  -- We test via a shell wrapper: 'sh -c cat' ignores positional args and reads stdin.
  local result = cli.run_pager("sh -c cat", content, "foo.tl")
  assert(result ~= nil, "run_pager with sh -c cat should succeed")
  assert(result:find("local x") ~= nil, "output should contain input text, got: " .. tostring(result))
end
test_run_pager_cat_passthrough()

local function test_run_pager_empty_input()
  local result = cli.run_pager("cat", "", "foo.tl")
  assert(result == nil, "run_pager with empty content should return nil")
end
test_run_pager_empty_input()

local function test_run_pager_nil_pager()
  local result = cli.run_pager(nil, "content", "foo.tl")
  assert(result == nil, "run_pager with nil pager should return nil")
end
test_run_pager_nil_pager()

local function test_run_pager_invalid_tool()
  local result = cli.run_pager("/nonexistent/tool/xyz", "content", "foo.tl")
  assert(result == nil, "run_pager with nonexistent tool should return nil, got: " .. tostring(result))
end
test_run_pager_invalid_tool()

local function test_run_pager_nil_filename()
  local result = cli.run_pager("cat", "content", nil)
  assert(result == nil, "run_pager with nil file_name should return nil")
end
test_run_pager_nil_filename()

local function test_run_pager_empty_filename()
  local result = cli.run_pager("cat", "content", "")
  assert(result == nil, "run_pager with empty file_name should return nil")
end
test_run_pager_empty_filename()

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
