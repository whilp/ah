#!/usr/bin/env cosmic
-- test_loop.tl: tests for agent loop module (tool display helpers)
local json = require("cosmic.json")
local loop = require("ah.loop")

-- Tests for tool_key_param (fallback to tool_input parsing)
local function test_tool_key_param_bash()
  local key = loop.tool_key_param("bash", '{"command":"ls -la"}', nil)
  assert(key == "ls -la", "should extract bash command")
end
test_tool_key_param_bash()

local function test_tool_key_param_bash_no_truncate()
  local long_cmd = string.rep("x", 100)
  local key = loop.tool_key_param("bash", '{"command":"' .. long_cmd .. '"}', nil)
  assert(key == long_cmd, "should return full command without truncation: got " .. #key .. " chars")
end
test_tool_key_param_bash_no_truncate()

local function test_tool_key_param_read()
  local key = loop.tool_key_param("read", '{"path":"/tmp/foo.txt"}', nil)
  assert(key == "/tmp/foo.txt", "should extract read path")
end
test_tool_key_param_read()

local function test_tool_key_param_write()
  local key = loop.tool_key_param("write", '{"path":"/tmp/bar.txt","content":"hello"}', nil)
  assert(key == "/tmp/bar.txt", "should extract write path")
end
test_tool_key_param_write()

local function test_tool_key_param_edit()
  local key = loop.tool_key_param("edit", '{"path":"/tmp/file.lua","old_string":"foo","new_string":"bar"}', nil)
  assert(key == "/tmp/file.lua", "should show path only: " .. key)
end
test_tool_key_param_edit()

local function test_tool_key_param_nil_input()
  local key = loop.tool_key_param("bash", nil, nil)
  assert(key == "", "should return empty string for nil input")
end
test_tool_key_param_nil_input()

local function test_tool_key_param_invalid_json()
  local key = loop.tool_key_param("bash", "not json", nil)
  assert(key == "", "should return empty string for invalid json")
end
test_tool_key_param_invalid_json()

local function test_tool_key_param_unknown_tool()
  local key = loop.tool_key_param("unknown_tool", '{"foo":"bar"}', nil)
  assert(key == "", "should return empty string for unknown tool")
end
test_tool_key_param_unknown_tool()

-- Tests for tool_key_param with details (structured data)
local function test_tool_key_param_details_read()
  local details = json.encode({path = "/tmp/foo.txt", line_count = 42})
  local key = loop.tool_key_param("read", '{"path":"/tmp/foo.txt"}', details)
  assert(key == "/tmp/foo.txt", "should use path from details")
end
test_tool_key_param_details_read()

local function test_tool_key_param_details_bash()
  local details = json.encode({command = "echo hello", exit_code = 0})
  local key = loop.tool_key_param("bash", '{"command":"echo hello"}', details)
  assert(key == "echo hello", "should use command from details")
end
test_tool_key_param_details_bash()

local function test_tool_key_param_details_bash_no_truncate()
  local long_cmd = string.rep("y", 100)
  local details = json.encode({command = long_cmd, exit_code = 0})
  local key = loop.tool_key_param("bash", '{"command":"x"}', details)
  assert(key == long_cmd, "should return full command from details without truncation: got " .. #key .. " chars")
end
test_tool_key_param_details_bash_no_truncate()

local function test_tool_key_param_details_edit()
  local details = json.encode({path = "/tmp/file.lua", old_lines = 5, new_lines = 7})
  local key = loop.tool_key_param("edit", '{"path":"/tmp/file.lua","old_string":"x","new_string":"y"}', details)
  assert(key == "/tmp/file.lua", "should show path only from details: " .. key)
end
test_tool_key_param_details_edit()

local function test_tool_key_param_details_write()
  local details = json.encode({path = "/tmp/out.txt", bytes = 1024})
  local key = loop.tool_key_param("write", '{"path":"/tmp/out.txt"}', details)
  assert(key == "/tmp/out.txt", "should use path from details")
end
test_tool_key_param_details_write()

local function test_tool_key_param_details_override()
  -- Details should take precedence over tool_input
  local details = json.encode({path = "/details/path.txt"})
  local key = loop.tool_key_param("read", '{"path":"/input/path.txt"}', details)
  assert(key == "/details/path.txt", "details should override tool_input: " .. key)
end
test_tool_key_param_details_override()

local function test_tool_key_param_nil_details_fallback()
  -- nil details should fall back to tool_input
  local key = loop.tool_key_param("read", '{"path":"/fallback/path.txt"}', nil)
  assert(key == "/fallback/path.txt", "should fall back to tool_input: " .. key)
end
test_tool_key_param_nil_details_fallback()

-- Tests for turn_signature
local function test_turn_signature_single()
  local tool_calls = {
    {name = "bash", input = {command = "ls -la"}},
  }
  local sig = loop.turn_signature(tool_calls)
  assert(sig == "bash:ls -la", "single tool call signature: " .. sig)
end
test_turn_signature_single()

local function test_turn_signature_multiple()
  local tool_calls = {
    {name = "read", input = {path = "/tmp/foo.txt"}},
    {name = "bash", input = {command = "echo hello"}},
  }
  local sig = loop.turn_signature(tool_calls)
  assert(sig == "read:/tmp/foo.txt|bash:echo hello", "multi tool call signature: " .. sig)
end
test_turn_signature_multiple()

local function test_turn_signature_empty()
  local tool_calls: {any} = {}
  local sig = loop.turn_signature(tool_calls)
  assert(sig == "", "empty tool calls should give empty signature: " .. sig)
end
test_turn_signature_empty()

local function test_turn_signature_edit()
  local tool_calls = {
    {name = "edit", input = {path = "/tmp/file.lua", old_string = "foo", new_string = "bar"}},
  }
  local sig = loop.turn_signature(tool_calls)
  assert(sig:match("edit:"), "should start with edit: " .. sig)
  assert(sig:match("/tmp/file.lua"), "should include path: " .. sig)
  -- Should include old_string and new_string for precise signatures
  assert(sig:match("foo"), "should include old_string: " .. sig)
  assert(sig:match("bar"), "should include new_string: " .. sig)
end
test_turn_signature_edit()

-- Edits to the same file with different content must produce different signatures
local function test_turn_signature_edit_different_content()
  local calls_a = {
    {name = "edit", input = {path = "/tmp/file.lua", old_string = "alpha", new_string = "beta"}},
  }
  local calls_b = {
    {name = "edit", input = {path = "/tmp/file.lua", old_string = "gamma", new_string = "delta"}},
  }
  local sig_a = loop.turn_signature(calls_a)
  local sig_b = loop.turn_signature(calls_b)
  assert(sig_a ~= sig_b, "edits with different content should have different signatures")
end
test_turn_signature_edit_different_content()

-- Edits to the same file with the same content must produce identical signatures
local function test_turn_signature_edit_same_content()
  local calls_a = {
    {name = "edit", input = {path = "/tmp/file.lua", old_string = "foo", new_string = "bar"}},
  }
  local calls_b = {
    {name = "edit", input = {path = "/tmp/file.lua", old_string = "foo", new_string = "bar"}},
  }
  local sig_a = loop.turn_signature(calls_a)
  local sig_b = loop.turn_signature(calls_b)
  assert(sig_a == sig_b, "edits with same content should have same signatures")
end
test_turn_signature_edit_same_content()

local function test_turn_signature_deterministic()
  local tool_calls = {
    {name = "bash", input = {command = "ls"}},
    {name = "read", input = {path = "/tmp/a.txt"}},
  }
  local sig1 = loop.turn_signature(tool_calls)
  local sig2 = loop.turn_signature(tool_calls)
  assert(sig1 == sig2, "same tool calls should produce same signature")
end
test_turn_signature_deterministic()

-- Tests for check_loop
local function test_check_loop_empty()
  local count = loop.check_loop({})
  assert(count == 0, "empty history should return 0: " .. count)
end
test_check_loop_empty()

local function test_check_loop_single()
  local count = loop.check_loop({"bash:ls"})
  assert(count == 1, "single entry should return 1: " .. count)
end
test_check_loop_single()

local function test_check_loop_no_repeat()
  local count = loop.check_loop({"bash:ls", "read:/tmp/foo", "bash:pwd"})
  assert(count == 1, "no repeat should return 1: " .. count)
end
test_check_loop_no_repeat()

local function test_check_loop_two_repeat()
  local count = loop.check_loop({"bash:ls", "bash:ls"})
  assert(count == 2, "two identical should return 2: " .. count)
end
test_check_loop_two_repeat()

local function test_check_loop_three_repeat()
  local count = loop.check_loop({"read:/tmp/a", "bash:ls", "bash:ls", "bash:ls"})
  assert(count == 3, "three consecutive identical should return 3: " .. count)
end
test_check_loop_three_repeat()

local function test_check_loop_broken_sequence()
  local count = loop.check_loop({"bash:ls", "bash:ls", "read:/tmp/a", "bash:ls"})
  assert(count == 1, "broken sequence should return 1: " .. count)
end
test_check_loop_broken_sequence()

local function test_check_loop_five_repeat()
  local history = {"bash:ls", "bash:ls", "bash:ls", "bash:ls", "bash:ls"}
  local count = loop.check_loop(history)
  assert(count == 5, "five identical should return 5: " .. count)
end
test_check_loop_five_repeat()

-- Test thresholds are exported and sensible
local function test_thresholds()
  assert(loop.LOOP_WARN_THRESHOLD == 3, "LOOP_WARN_THRESHOLD should be 3")
  assert(loop.LOOP_BREAK_THRESHOLD == 5, "LOOP_BREAK_THRESHOLD should be 5")
  assert(loop.LOOP_BREAK_THRESHOLD > loop.LOOP_WARN_THRESHOLD, "break should be greater than warn")
end
test_thresholds()

print("all loop tests passed")

-- Tests for shorten_path
local cfs = require("cosmic.fs")
local function test_shorten_path_under_cwd()
  local cwd = cfs.getcwd() or "/tmp"
  local p = cwd .. "/foo/bar.txt"
  local short = loop.shorten_path(p)
  assert(short == "foo/bar.txt", "should strip cwd prefix: " .. short)
end
test_shorten_path_under_cwd()

local function test_shorten_path_outside_cwd()
  local p = "/not/under/cwd/file.txt"
  local short = loop.shorten_path(p)
  assert(short == p, "should leave paths outside cwd unchanged: " .. short)
end
test_shorten_path_outside_cwd()

local function test_shorten_path_cwd_itself()
  local cwd = cfs.getcwd() or "/tmp"
  local short = loop.shorten_path(cwd)
  assert(short == ".", "should return . for cwd itself: " .. short)
end
test_shorten_path_cwd_itself()

local function test_shorten_path_relative()
  local short = loop.shorten_path("relative/path.txt")
  assert(short == "relative/path.txt", "should leave relative paths unchanged: " .. short)
end
test_shorten_path_relative()

-- Test that tool_key_param shortens paths under cwd
local function test_tool_key_param_shortens_path()
  local cwd = cfs.getcwd() or "/tmp"
  local json = require("cosmic.json")
  local details = json.encode({path = cwd .. "/lib/ah/loop.tl"})
  local key = loop.tool_key_param("read", '{}', details)
  assert(key == "lib/ah/loop.tl", "should shorten path in details: " .. key)
end
test_tool_key_param_shortens_path()

-- Test that run_agent returns a stop_reason string
local function test_run_agent_signature()
  -- Verify run_agent is exported and callable
  assert(type(loop.run_agent) == "function", "run_agent should be a function")
  -- The function should return a string (stop_reason)
  -- We can't easily test without mocking the API, but we document the contract
  print("✓ run_agent is exported as a function")
end
test_run_agent_signature()

-- Tests for wrap_command
local function test_wrap_command_short()
  local cmd = "ls -la"
  local result = loop.wrap_command(cmd, 80, "    ")
  assert(result == cmd, "short command should be unchanged: " .. result)
end
test_wrap_command_short()

local function test_wrap_command_long_with_flags()
  local cmd = "gh issue list --repo whilp/ah --label todo --state open --json number,title,body,url --limit 100"
  local result = loop.wrap_command(cmd, 60, "    ")
  assert(result:find("\\\n"), "should contain backslash continuation: " .. result)
  -- Each line of wrapped output should fit within width (plus \ and trailing space)
  for line in result:gmatch("[^\n]+") do
    local clean = line:gsub(" \\$", "")
    assert(#clean <= 60, "line should fit within width: " .. #clean .. " chars: " .. line)
  end
end
test_wrap_command_long_with_flags()

local function test_wrap_command_no_flags()
  -- Long command with no flag boundaries
  local cmd = "echo " .. string.rep("word ", 20)
  cmd = cmd:gsub("%s+$", "")
  local result = loop.wrap_command(cmd, 40, "    ")
  assert(result:find("\\\n"), "should wrap at space boundaries: " .. result)
end
test_wrap_command_no_flags()

local function test_wrap_command_preserves_tokens()
  local cmd = "gh issue list --repo whilp/ah --label todo --state open"
  local result = loop.wrap_command(cmd, 40, "    ")
  -- All original tokens should be present
  for token in cmd:gmatch("%S+") do
    assert(result:find(token, 1, true), "should preserve token: " .. token)
  end
end
test_wrap_command_preserves_tokens()

local function test_wrap_command_exact_width()
  -- Command exactly at width should not wrap
  local cmd = string.rep("x", 80)
  local result = loop.wrap_command(cmd, 80, "    ")
  assert(result == cmd, "command at exact width should not wrap")
end
test_wrap_command_exact_width()

local function test_wrap_command_default_width()
  -- Should wrap a long command at width 80
  local cmd = "gh issue list --repo whilp/ah --label todo --state open --json number,title,body,url,labels,createdAt --limit 100"
  local result = loop.wrap_command(cmd, 80, "    ")
  assert(result:find("\\\n"), "should wrap at width 80: " .. result)
end
test_wrap_command_default_width()

local function test_wrap_command_comment_break()
  -- Commands with # comments should break at # boundaries
  local cmd = "# check how bin/ah works # it's a wrapper that sets env vars # Let me check grep -r embed Makefile"
  local result = loop.wrap_command(cmd, 120, "    ")
  -- Should break at # tokens even though line hasn't hit width limit
  assert(result:find("\\\n"), "should contain line breaks: " .. result)
  -- Count the lines
  local lines = 0
  for _ in result:gmatch("[^\n]+") do lines = lines + 1 end
  assert(lines >= 3, "should have at least 3 lines (one per # comment): got " .. lines)
  -- First line should start with the first # comment
  local first_line = result:match("^([^\n]+)")
  assert(first_line:sub(1, 1) == "#", "first line should start with #: " .. first_line)
  -- Subsequent lines should start with indent + #
  local second_line = result:match("\n(    #[^\n]*)")
  assert(second_line, "second line should start with indent + #")
end
test_wrap_command_comment_break()

local function test_wrap_command_comment_no_false_positive()
  -- A # inside a word (no space before) should not trigger a break
  local cmd = "echo color:#fff background:#000 border:#ccc other:#aaa"
  local result = loop.wrap_command(cmd, 120, "    ")
  -- These are single tokens (no space before #), so no break expected
  assert(not result:find("\\\n"), "should not break inside tokens: " .. result)
end
test_wrap_command_comment_no_false_positive()

local function test_wrap_command_multiline_shows_first_line()
  -- Multi-line command: only first line shown with "..." suffix
  local cmd = "git log --oneline -1 origin/work/241-c4\ngit status\ngit diff"
  local result = loop.wrap_command(cmd, 80, "    ")
  assert(not result:find("\n"), "result should not contain newlines: " .. result)
  assert(result == "git log --oneline -1 origin/work/241-c4 ...", "should show first line + ...: " .. result)
end
test_wrap_command_multiline_shows_first_line()

local function test_wrap_command_multiline_trailing_only()
  -- Multi-line command where remaining lines are empty/whitespace: no suffix
  local cmd = "ls -la\n\n"
  local result = loop.wrap_command(cmd, 80, "    ")
  assert(result == "ls -la", "trailing blank lines should not add suffix: " .. result)
end
test_wrap_command_multiline_trailing_only()

local function test_wrap_command_multiline_long_first_line()
  -- Multi-line command where first line itself is long: wraps after normalization
  local cmd = "gh issue edit 241 --remove-label \"doing\" --add-label \"todo\" 2>&1\nsome other line"
  local result = loop.wrap_command(cmd, 40, "    ")
  -- Should not contain the second line
  assert(not result:find("some other line"), "should not include second line: " .. result)
  -- Should end with "..."
  assert(result:find("%.%.%.$"), "should end with ...: " .. result)
end
test_wrap_command_multiline_long_first_line()

local function test_wrap_command_single_line_unchanged()
  -- Single-line command not affected by multiline normalization
  local cmd = "echo hello"
  local result = loop.wrap_command(cmd, 80, "    ")
  assert(result == cmd, "single-line command unchanged: " .. result)
end
test_wrap_command_single_line_unchanged()

-- Tests for measure_payload_bytes
local function test_measure_payload_bytes_empty()
  local result = loop.measure_payload_bytes({})
  assert(type(result) == "number", "should return a number")
  assert(result > 0, "empty array encodes to non-empty JSON: got " .. result)
  -- [] encodes to 2 bytes
  assert(result <= 10, "empty array should be small: got " .. result)
end
test_measure_payload_bytes_empty()

local function test_measure_payload_bytes_text()
  local msgs = {
    {role = "user", content = {{type = "text", text = "hello world"}}},
  }
  local result = loop.measure_payload_bytes(msgs)
  assert(result > 0, "text message should have positive byte count: got " .. result)
  assert(result > 20, "text message with content should be > 20 bytes: got " .. result)
end
test_measure_payload_bytes_text()

local function test_measure_payload_bytes_large()
  local big_text = string.rep("x", 100000)
  local msgs = {
    {role = "user", content = {{type = "text", text = big_text}}},
  }
  local result = loop.measure_payload_bytes(msgs)
  assert(result > 100000, "large content should produce > 100000 byte payload: got " .. result)
end
test_measure_payload_bytes_large()

local function test_payload_warn_threshold_constant()
  local t = loop.PAYLOAD_WARN_BYTES
  assert(type(t) == "number", "PAYLOAD_WARN_BYTES should be a number")
  assert(t > 0, "PAYLOAD_WARN_BYTES should be positive: got " .. t)
  assert(t >= 100000, "PAYLOAD_WARN_BYTES should be at least 100KB: got " .. t)
end
test_payload_warn_threshold_constant()

print("all payload tests passed")
