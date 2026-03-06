#!/usr/bin/env cosmic
-- test_tool_render.tl: tests for unified braille bracket rendering of non-bash tools
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local cli = require("ah.cli")
local events = require("ah.events")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR") or "/tmp"

local function capture_stderr(fn: function()): string
  local tmpfile = fs.join(TEST_TMPDIR, "test_stderr_tr_" .. tostring(os.time()) .. ".txt")
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

local function test_tool_call_start_non_bash_braille()
  local handler = cli.make_cli_handler(nil)
  local output = capture_stderr(function()
      handler({
          event_type = "tool_call_start",
          tool_name = "read",
          tool_key = "lib/ah/cli.tl",
          tool_input = '{"path":"lib/ah/cli.tl"}',
          tool_index = 1,
          tool_count = 1,
        } as events.EventData)
    end)
  assert(output:match("read lib/ah/cli.tl"), "should show tool name and key, got: " .. output)
  print("✓ non-bash tool_call_start shows braille prefix with tool name and key")
end
test_tool_call_start_non_bash_braille()

local function test_tool_call_end_non_bash_summary()
  local handler = cli.make_cli_handler(nil)
  local output = capture_stderr(function()
      handler({
          event_type = "tool_call_end",
          tool_name = "read",
          tool_key = "lib/ah/cli.tl",
          tool_output = "line1\nline2\nline3\n",
          is_error = false,
          duration_ms = 250,
          tool_index = 1,
          tool_count = 1,
        } as events.EventData)
    end)
  assert(output:match("0%.2s"), "should show elapsed time, got: " .. output)
  assert(output:match("3 lines"), "should show line count, got: " .. output)
  assert(not output:match("error"), "should not show error, got: " .. output)
  print("✓ non-bash tool_call_end shows braille summary with duration and line count")
end
test_tool_call_end_non_bash_summary()

local function test_tool_call_end_non_bash_error()
  local handler = cli.make_cli_handler(nil)
  local output = capture_stderr(function()
      handler({
          event_type = "tool_call_end",
          tool_name = "write",
          tool_key = "foo.txt",
          tool_output = "permission denied",
          is_error = true,
          duration_ms = 100,
          tool_index = 1,
          tool_count = 1,
        } as events.EventData)
    end)
  assert(output:match("0%.1s"), "should show elapsed time, got: " .. output)
  assert(output:match("error"), "should show error in summary, got: " .. output)
  assert(not output:match("exit"), "non-bash error should not show exit code, got: " .. output)
  print("✓ non-bash tool_call_end shows error in summary without exit code")
end
test_tool_call_end_non_bash_error()

local function test_tool_call_end_no_output()
  local handler = cli.make_cli_handler(nil)
  local output = capture_stderr(function()
      handler({
          event_type = "tool_call_end",
          tool_name = "edit",
          tool_key = "foo.tl",
          tool_output = "(no output)",
          is_error = false,
          duration_ms = 40,
          tool_index = 1,
          tool_count = 1,
        } as events.EventData)
    end)
  assert(output:match("0%.0s"), "should show elapsed time, got: " .. output)
  assert(not output:match("line"), "no-output should not show line count, got: " .. output)
  print("✓ non-bash tool_call_end with no output omits line count")
end
test_tool_call_end_no_output()

local function test_tool_call_start_no_key()
  local handler = cli.make_cli_handler(nil)
  local output = capture_stderr(function()
      handler({
          event_type = "tool_call_start",
          tool_name = "skill",
          tool_key = "",
          tool_input = "{}",
          tool_index = 1,
          tool_count = 1,
        } as events.EventData)
    end)
  assert(output:match("skill"), "should show tool name, got: " .. output)
  print("✓ tool_call_start with no key shows only tool name")
end
test_tool_call_start_no_key()

print("PASS")
