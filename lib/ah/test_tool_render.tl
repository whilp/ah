#!/usr/bin/env cosmic
-- test_tool_render.tl: tests for unified braille bracket rendering of non-bash tools
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local cli = require("ah.cli")
local events = require("ah.events")
local cenv = require("cosmic.env")
local time = require("cosmic.time")

local TEST_TMPDIR = cenv.get("TEST_TMPDIR") or "/tmp"

local function capture_stderr(fn: function()): string
  local tmpfile = fs.join(TEST_TMPDIR, "test_stderr_tr_" .. tostring((time.now())) .. ".txt")
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

-- Head/tail preview tests

local function test_tool_call_end_read_strips_line_numbers()
  local handler = cli.make_cli_handler(nil)
  local output = capture_stderr(function()
      handler({
          event_type = "tool_call_end",
          tool_name = "read",
          tool_key = "foo.tl",
          tool_output = "1\tlocal x = 1\n2\tlocal y = 2\n3\treturn x + y\n",
          is_error = false,
          duration_ms = 50,
          tool_index = 1,
          tool_count = 1,
        } as events.EventData)
    end)
  assert(output:match("local x = 1"), "should show content without line number, got: " .. output)
  assert(not output:match("1\t"), "should strip line number prefix, got: " .. output)
  print("✓ read tool strips line number prefixes from display")
end
test_tool_call_end_read_strips_line_numbers()

local function test_tool_call_end_write_shows_content()
  local handler = cli.make_cli_handler(nil)
  local output = capture_stderr(function()
      handler({
          event_type = "tool_call_end",
          tool_name = "write",
          tool_key = "foo.tl",
          tool_output = "1\tlocal x = 1\n2\tlocal y = 2\n3\treturn x + y\n",
          is_error = false,
          duration_ms = 50,
          tool_index = 1,
          tool_count = 1,
        } as events.EventData)
    end)
  assert(output:match("local x = 1"), "should show written content, got: " .. output)
  assert(not output:match("1\t"), "should strip line number prefix, got: " .. output)
  print("✓ write tool shows content preview with line numbers stripped")
end
test_tool_call_end_write_shows_content()

local function test_tool_call_end_result_strips_line_numbers()
  local handler = cli.make_cli_handler(nil)
  local output = capture_stderr(function()
      handler({
          event_type = "tool_call_end",
          tool_name = "result",
          tool_key = "result",
          tool_output = "10\tline ten\n11\tline eleven\n",
          is_error = false,
          duration_ms = 30,
          tool_index = 1,
          tool_count = 1,
        } as events.EventData)
    end)
  assert(output:match("line ten"), "should show content without line number, got: " .. output)
  assert(not output:match("10\t"), "should strip line number prefix, got: " .. output)
  print("✓ result tool strips line number prefixes from display")
end
test_tool_call_end_result_strips_line_numbers()

local function test_tool_call_end_small_output_shows_all()
  local handler = cli.make_cli_handler(nil)
  local output = capture_stderr(function()
      handler({
          event_type = "tool_call_end",
          tool_name = "read",
          tool_key = "foo.tl",
          tool_output = "line1\nline2\nline3\nline4\nline5\n",
          is_error = false,
          duration_ms = 50,
          tool_index = 1,
          tool_count = 1,
        } as events.EventData)
    end)
  assert(output:match("line1"), "should show line1, got: " .. output)
  assert(output:match("line5"), "should show line5, got: " .. output)
  assert(not output:match("hidden"), "should not show hidden for <=5 lines, got: " .. output)
  assert(not output:match("more lines"), "should not show more lines for <=5 lines, got: " .. output)
  print("✓ small output (<=5 lines) shows all lines")
end
test_tool_call_end_small_output_shows_all()

local function test_tool_call_end_medium_output_shows_head()
  local handler = cli.make_cli_handler(nil)
  local lines: {string} = {}
  for i = 1, 8 do table.insert(lines, "line" .. tostring(i)) end
  local output = capture_stderr(function()
      handler({
          event_type = "tool_call_end",
          tool_name = "bash",
          tool_key = "seq 8",
          tool_output = table.concat(lines, "\n"),
          is_error = false,
          duration_ms = 50,
          tool_index = 1,
          tool_count = 1,
        } as events.EventData)
    end)
  assert(output:match("line1"), "should show line1, got: " .. output)
  assert(output:match("line5"), "should show line5, got: " .. output)
  assert(not output:match("line6"), "should not show line6, got: " .. output)
  assert(output:match("3 more lines"), "should show '3 more lines', got: " .. output)
  print("✓ medium output (6-10 lines) shows first 5 + summary")
end
test_tool_call_end_medium_output_shows_head()

local function test_tool_call_end_large_output_shows_head_tail()
  local handler = cli.make_cli_handler(nil)
  local lines: {string} = {}
  for i = 1, 20 do table.insert(lines, "line" .. tostring(i)) end
  local output = capture_stderr(function()
      handler({
          event_type = "tool_call_end",
          tool_name = "read",
          tool_key = "big.tl",
          tool_output = table.concat(lines, "\n"),
          is_error = false,
          duration_ms = 50,
          tool_index = 1,
          tool_count = 1,
        } as events.EventData)
    end)
  assert(output:match("line1"), "should show line1, got: " .. output)
  assert(output:match("line5"), "should show line5, got: " .. output)
  assert(not output:match("line6"), "should not show line6, got: " .. output)
  assert(not output:match("line15"), "should not show line15, got: " .. output)
  assert(output:match("line16"), "should show line16, got: " .. output)
  assert(output:match("line20"), "should show line20, got: " .. output)
  assert(output:match("10 lines hidden"), "should show '10 lines hidden', got: " .. output)
  print("✓ large output (>10 lines) shows first 5 + last 5 with hidden count")
end
test_tool_call_end_large_output_shows_head_tail()

print("PASS")
