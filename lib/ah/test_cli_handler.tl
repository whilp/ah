#!/usr/bin/env cosmic
-- test_cli_handler.tl: tests for make_cli_handler color output
local events = require("ah.events")
local init = require("ah.init")

-- Cast to access make_cli_handler
local record InitCli
  make_cli_handler: function(boolean): events.EventCallback
end
local cli = require("ah.init") as InitCli

-- Helper: capture stderr output from a handler call.
-- We redirect stderr to a temp file, call the handler, then read it back.
local function capture_stderr(handler: events.EventCallback, event: events.EventData): string
  local tmpfile = os.tmpname()
  local saved = io.stderr
  local f = io.open(tmpfile, "w")
  io.stderr = f
  handler(event)
  f:close()
  io.stderr = saved
  local rf = io.open(tmpfile, "r")
  local output = rf:read("*a")
  rf:close()
  os.remove(tmpfile)
  return output
end

-- ANSI escape code constants (must match init.tl)
local ESC = "\27["
local CYAN = ESC .. "36m"
local RED = ESC .. "31m"
local YELLOW = ESC .. "33m"
local DIM = ESC .. "2m"
local RESET = ESC .. "0m"

-- Test: tool_call_end renders tool name in cyan with timing
local function test_tool_call_end_color()
  local handler = cli.make_cli_handler(true)
  local event = events.tool_call_end("bash", "ok", false, 1500, "ls -la", 1, 1)
  local output = capture_stderr(handler, event)
  -- Tool name line should start with CYAN
  assert(output:find(CYAN, 1, true), "tool name should be cyan, got: " .. output)
  assert(output:find("bash", 1, true), "should contain tool name")
  assert(output:find("1.5s", 1, true), "should contain elapsed time")
  assert(output:find(RESET, 1, true), "should have RESET")
  print("✓ tool_call_end renders cyan tool name with timing")
end
test_tool_call_end_color()

-- Test: tool_call_end with error renders in red
local function test_tool_call_end_error_color()
  local handler = cli.make_cli_handler(true)
  local event = events.tool_call_end("bash", "command not found", true, 500, "bad-cmd", 1, 1)
  local output = capture_stderr(handler, event)
  -- Tool name should be RED when is_error
  assert(output:find(RED, 1, true), "error tool name should be red, got: " .. output)
  -- Error output should also be red
  assert(output:find(RED .. "  command not found", 1, true), "error output should be red, got: " .. output)
  print("✓ tool_call_end renders red for errors")
end
test_tool_call_end_error_color()

-- Test: tool_call_end normal output uses DIM
local function test_tool_call_end_normal_output_dim()
  local handler = cli.make_cli_handler(true)
  local event = events.tool_call_end("read", "line1\nline2", false, 200, "/tmp/file.txt", 1, 1)
  local output = capture_stderr(handler, event)
  -- Output lines should use DIM
  assert(output:find(DIM .. "  line1", 1, true), "normal output should use DIM, got: " .. output)
  assert(output:find(DIM .. "  line2", 1, true), "second line should use DIM")
  print("✓ tool_call_end normal output uses DIM")
end
test_tool_call_end_normal_output_dim()

-- Test: error event renders in red
local function test_error_event_red()
  local handler = cli.make_cli_handler(true)
  local event = events.error_event("something went wrong")
  local output = capture_stderr(handler, event)
  assert(output:find(RED, 1, true), "error should be red, got: " .. output)
  assert(output:find("something went wrong", 1, true), "should contain error message")
  print("✓ error event renders in red")
end
test_error_event_red()

-- Test: budget_exceeded renders in yellow
local function test_budget_exceeded_yellow()
  local handler = cli.make_cli_handler(true)
  local event = events.budget_exceeded(80000, 20000, 100000)
  local output = capture_stderr(handler, event)
  assert(output:find(YELLOW, 1, true), "budget exceeded should be yellow, got: " .. output)
  assert(output:find("token budget exceeded", 1, true), "should contain message")
  print("✓ budget_exceeded renders in yellow")
end
test_budget_exceeded_yellow()

-- Test: no color when force_tty is false (non-TTY mode)
local function test_no_color_non_tty()
  local handler = cli.make_cli_handler(false)
  local event = events.tool_call_end("bash", "ok", false, 1000, "ls", 1, 1)
  local output = capture_stderr(handler, event)
  -- Should not contain any ANSI escape codes
  assert(not output:find("\27[", 1, true), "non-TTY should have no ANSI codes, got: " .. output)
  assert(output:find("bash", 1, true), "should still contain tool name")
  print("✓ no color in non-TTY mode")
end
test_no_color_non_tty()

-- Test: tool output truncation with overflow count
local function test_tool_output_truncation()
  local handler = cli.make_cli_handler(true)
  local long_output = "line1\nline2\nline3\nline4\nline5"
  local event = events.tool_call_end("bash", long_output, false, 100, "cmd", 1, 1)
  local output = capture_stderr(handler, event)
  assert(output:find("line1", 1, true), "should show first line")
  assert(output:find("line2", 1, true), "should show second line")
  assert(output:find("line3", 1, true), "should show third line")
  assert(not output:find("line4", 1, true), "should not show fourth line")
  assert(output:find("2 more lines", 1, true), "should show overflow count")
  print("✓ tool output truncation works")
end
test_tool_output_truncation()

-- Test: tool key param shows with $ prefix for bash
local function test_bash_key_dollar_prefix()
  local handler = cli.make_cli_handler(true)
  local event = events.tool_call_end("bash", "ok", false, 100, "ls -la", 1, 1)
  local output = capture_stderr(handler, event)
  assert(output:find("$ ls %-la", nil, false), "bash key should have $ prefix, got: " .. output)
  print("✓ bash key has $ prefix")
end
test_bash_key_dollar_prefix()

-- Test: non-bash tool key param has no $ prefix
local function test_non_bash_key_no_prefix()
  local handler = cli.make_cli_handler(true)
  local event = events.tool_call_end("read", "contents", false, 100, "/tmp/file.txt", 1, 1)
  local output = capture_stderr(handler, event)
  assert(output:find("  /tmp/file.txt", 1, true), "read key should not have $ prefix, got: " .. output)
  assert(not output:find("$ /tmp/file.txt", 1, true), "should not have $ prefix for non-bash")
  print("✓ non-bash key has no $ prefix")
end
test_non_bash_key_no_prefix()

-- Test: compaction_triggered renders in DIM
local function test_compaction_dim()
  local handler = cli.make_cli_handler(true)
  local event = events.compaction_triggered(90000, 100000)
  local output = capture_stderr(handler, event)
  assert(output:find(DIM, 1, true), "compaction should use DIM, got: " .. output)
  assert(output:find("compacting conversation", 1, true), "should contain message")
  print("✓ compaction_triggered renders in DIM")
end
test_compaction_dim()

-- Test: agent_start in non-TTY mode shows prompt without color
local function test_agent_start_non_tty()
  local handler = cli.make_cli_handler(false)
  local event = events.agent_start("opus", "hello world", nil)
  local output = capture_stderr(handler, event)
  assert(output:find(">>> hello world", 1, true), "non-TTY should echo prompt, got: " .. output)
  assert(not output:find("\27[", 1, true), "non-TTY prompt should have no ANSI codes")
  print("✓ agent_start non-TTY shows plain prompt")
end
test_agent_start_non_tty()

print("all cli handler tests passed")
