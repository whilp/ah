#!/usr/bin/env cosmic
-- test_cli.tl: tests for CLI display handler and output formatting
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local cli = require("ah.cli")
local hl = require("ah.highlight")
local events = require("ah.events")
local cenv = require("cosmic.env")

local TEST_TMPDIR = cenv.get("TEST_TMPDIR") or "/tmp"

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
  assert(output:match("100%.0k"), "agent_end output should contain '100.0k' context, got: " .. output)
  assert(output:match("ctx"), "agent_end output should contain 'ctx', got: " .. output)
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
  assert(output:match("1%.0m"), "nil model should fall back to 1.0m budget, got: " .. output)
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
  assert(not output:match("ctx"), "zero tokens should produce no ctx line, got: " .. output)
end
test_make_cli_handler_agent_end_no_tokens_no_output()

local function test_make_cli_handler_agent_end_with_cache()
  local handler = cli.make_cli_handler(nil)
  local output = capture_stderr(function()
      handler({event_type = "agent_start", model = "claude-opus-4-6"} as events.EventData)
      handler({
          event_type = "agent_end",
          total_input_tokens = 73000,
          total_output_tokens = 19000,
          total_cache_read_tokens = 72000,
        } as events.EventData)
    end)
  assert(output:match("73%.0k"), "should show 73.0k context, got: " .. output)
  assert(output:match("cached"), "should show cached, got: " .. output)
  assert(output:match("72%.0k"), "should show 72.0k cached, got: " .. output)
  assert(output:match("19%.0k"), "should show 19.0k output, got: " .. output)
  assert(output:match("ctx"), "should show ctx, got: " .. output)
  assert(output:match("7%%"), "should show 7%% utilization, got: " .. output)
  assert(output:match("1%.0m"), "should show 1.0m budget, got: " .. output)
end
test_make_cli_handler_agent_end_with_cache()

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

print("all cli tests passed")
