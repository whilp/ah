#!/usr/bin/env cosmic
-- test_cli.tl: tests for CLI display handler and output formatting
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local cli = require("ah.cli")
local events = require("ah.events")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR") or "/tmp"

-- Diff colorization tests

local function test_colorize_diff_line_plus()
  local result = cli.colorize_diff_line("+added line")
  assert(result == "\27[34m+added line\27[0m", "plus line should be blue, got: " .. result)
end
test_colorize_diff_line_plus()

local function test_colorize_diff_line_minus()
  local result = cli.colorize_diff_line("-removed line")
  assert(result == "\27[33m-removed line\27[0m", "minus line should be yellow, got: " .. result)
end
test_colorize_diff_line_minus()

local function test_colorize_diff_line_hunk()
  local result = cli.colorize_diff_line("@@ -1,3 +1,4 @@")
  assert(result == "\27[36m@@ -1,3 +1,4 @@\27[0m", "hunk header should be cyan, got: " .. result)
end
test_colorize_diff_line_hunk()

local function test_colorize_diff_line_header_plus()
  local result = cli.colorize_diff_line("+++ b/file.txt")
  assert(result == "\27[1m+++ b/file.txt\27[0m", "+++ header should be bold, got: " .. result)
end
test_colorize_diff_line_header_plus()

local function test_colorize_diff_line_header_minus()
  local result = cli.colorize_diff_line("--- a/file.txt")
  assert(result == "\27[1m--- a/file.txt\27[0m", "--- header should be bold, got: " .. result)
end
test_colorize_diff_line_header_minus()

local function test_colorize_diff_line_plain()
  local result = cli.colorize_diff_line(" context line")
  assert(result == " context line", "context line should be unchanged, got: " .. result)
end
test_colorize_diff_line_plain()

-- Tool output colorization tests

local function test_colorize_tool_line_pass()
  local result, colored = cli.colorize_tool_line("PASS test_foo")
  assert(colored == true, "PASS should be colored")
  assert(result == "\27[1;34mPASS test_foo\27[0m", "PASS should be blue+bold, got: " .. result)
end
test_colorize_tool_line_pass()

local function test_colorize_tool_line_pass_prefix()
  local result, colored = cli.colorize_tool_line("PASSING all tests")
  assert(colored == true, "PASSING should be colored")
  assert(result:find("\27%[1;34m"), "PASSING should be blue+bold")
end
test_colorize_tool_line_pass_prefix()

local function test_colorize_tool_line_fail()
  local result, colored = cli.colorize_tool_line("FAIL test_bar")
  assert(colored == true, "FAIL should be colored")
  assert(result == "\27[1;33mFAIL test_bar\27[0m", "FAIL should be yellow+bold, got: " .. result)
end
test_colorize_tool_line_fail()

local function test_colorize_tool_line_failure_prefix()
  local result, colored = cli.colorize_tool_line("FAILURE in module X")
  assert(colored == true, "FAILURE should be colored")
  assert(result:find("\27%[1;33m"), "FAILURE should be yellow+bold")
end
test_colorize_tool_line_failure_prefix()

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

local function test_colorize_tool_line_lowercase_pass()
  local result, colored = cli.colorize_tool_line("passed all tests")
  assert(colored == false, "lowercase 'passed' should not be colored")
  assert(result == "passed all tests", "lowercase 'passed' should be unchanged")
end
test_colorize_tool_line_lowercase_pass()

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

-- first_line tests

local function test_first_line_single_line()
  local result = cli.first_line("git status")
  assert(result == "git status", "single-line should be unchanged, got: " .. tostring(result))
end
test_first_line_single_line()

local function test_first_line_multi_line()
  local result = cli.first_line("git log --oneline -1 origin/work/241-c4\necho done")
  assert(result == "git log --oneline -1 origin/work/241-c4...", "multi-line should show first line with ..., got: " .. tostring(result))
end
test_first_line_multi_line()

local function test_first_line_three_lines()
  local result = cli.first_line("line1\nline2\nline3")
  assert(result == "line1...", "three-line should show only first line with ..., got: " .. tostring(result))
end
test_first_line_three_lines()

local function test_first_line_trailing_newline()
  -- a string ending in newline has an empty second "line"; still treat as multi-line
  local result = cli.first_line("git status\n")
  assert(result == "git status...", "trailing newline should add ..., got: " .. tostring(result))
end
test_first_line_trailing_newline()

local function test_first_line_empty_string()
  local result = cli.first_line("")
  assert(result == "", "empty string should be unchanged, got: " .. tostring(result))
end
test_first_line_empty_string()

print("all cli tests passed")
