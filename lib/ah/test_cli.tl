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

print("all cli tests passed")
