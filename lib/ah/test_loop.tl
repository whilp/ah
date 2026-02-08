#!/usr/bin/env cosmic
-- test_loop.tl: tests for agent loop module (tool display helpers)
local loop = require("ah.loop")

-- Tests for tool_key_param
local function test_tool_key_param_bash()
  local key = loop.tool_key_param("bash", '{"command":"ls -la"}')
  assert(key == "ls -la", "should extract bash command")
end
test_tool_key_param_bash()

local function test_tool_key_param_bash_truncate()
  local long_cmd = string.rep("x", 100)
  local key = loop.tool_key_param("bash", '{"command":"' .. long_cmd .. '"}')
  assert(#key == 80, "should truncate to 80 chars: got " .. #key)
  assert(key:sub(-3) == "...", "should end with ellipsis")
end
test_tool_key_param_bash_truncate()

local function test_tool_key_param_read()
  local key = loop.tool_key_param("read", '{"path":"/tmp/foo.txt"}')
  assert(key == "/tmp/foo.txt", "should extract read path")
end
test_tool_key_param_read()

local function test_tool_key_param_write()
  local key = loop.tool_key_param("write", '{"path":"/tmp/bar.txt","content":"hello"}')
  assert(key == "/tmp/bar.txt", "should extract write path")
end
test_tool_key_param_write()

local function test_tool_key_param_edit()
  local key = loop.tool_key_param("edit", '{"path":"/tmp/file.lua","old_string":"foo","new_string":"bar"}')
  assert(key:match("/tmp/file.lua"), "should include path")
  assert(key:match("foo"), "should include old_string preview")
  assert(key:match("bar"), "should include new_string preview")
end
test_tool_key_param_edit()

local function test_tool_key_param_nil_input()
  local key = loop.tool_key_param("bash", nil)
  assert(key == "", "should return empty string for nil input")
end
test_tool_key_param_nil_input()

local function test_tool_key_param_invalid_json()
  local key = loop.tool_key_param("bash", "not json")
  assert(key == "", "should return empty string for invalid json")
end
test_tool_key_param_invalid_json()

local function test_tool_key_param_unknown_tool()
  local key = loop.tool_key_param("unknown_tool", '{"foo":"bar"}')
  assert(key == "", "should return empty string for unknown tool")
end
test_tool_key_param_unknown_tool()

print("all loop tests passed")
