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

local function test_tool_key_param_bash_truncate()
  local long_cmd = string.rep("x", 100)
  local key = loop.tool_key_param("bash", '{"command":"' .. long_cmd .. '"}', nil)
  assert(#key == 80, "should truncate to 80 chars: got " .. #key)
  assert(key:sub(-3) == "...", "should end with ellipsis")
end
test_tool_key_param_bash_truncate()

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
  assert(key:match("/tmp/file.lua"), "should include path")
  assert(key:match("foo"), "should include old_string preview")
  assert(key:match("bar"), "should include new_string preview")
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

local function test_tool_key_param_details_bash_truncate()
  local long_cmd = string.rep("y", 100)
  local details = json.encode({command = long_cmd, exit_code = 0})
  local key = loop.tool_key_param("bash", '{"command":"x"}', details)
  assert(#key == 80, "should truncate details command to 80 chars: got " .. #key)
  assert(key:sub(-3) == "...", "should end with ellipsis")
end
test_tool_key_param_details_bash_truncate()

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

-- Test that run_agent returns a stop_reason string
local function test_run_agent_signature()
  -- Verify run_agent is exported and callable
  assert(type(loop.run_agent) == "function", "run_agent should be a function")
  -- The function should return a string (stop_reason)
  -- We can't easily test without mocking the API, but we document the contract
  print("✓ run_agent is exported as a function")
end
test_run_agent_signature()
