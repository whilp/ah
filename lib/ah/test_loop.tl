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
  assert(key:match("/tmp/file.lua"), "should include path from details")
  assert(key:match("5 → 7 lines"), "should include line change info: " .. key)
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

print("all loop tests passed")
