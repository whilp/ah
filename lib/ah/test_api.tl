#!/usr/bin/env run-test.lua
-- test_api.tl: tests for Claude API module
local api = require("ah.api")

local function test_extract_tool_calls_empty()
  local result = api.extract_tool_calls(nil)
  assert(#result == 0, "nil response should return empty table")

  result = api.extract_tool_calls({})
  assert(#result == 0, "empty response should return empty table")

  result = api.extract_tool_calls({content = {}})
  assert(#result == 0, "empty content should return empty table")
end
test_extract_tool_calls_empty()

local function test_extract_tool_calls_text_only()
  local response = {
    content = {
      {type = "text", text = "Hello world"},
    }
  }
  local result = api.extract_tool_calls(response)
  assert(#result == 0, "text-only response should return empty table")
end
test_extract_tool_calls_text_only()

local function test_extract_tool_calls_with_tools()
  local response = {
    content = {
      {type = "text", text = "Let me read that file"},
      {type = "tool_use", id = "tool_123", name = "read", input = {path = "/tmp/test"}},
      {type = "tool_use", id = "tool_456", name = "bash", input = {command = "echo hi"}},
    }
  }
  local result = api.extract_tool_calls(response)
  assert(#result == 2, "should extract 2 tool calls")
  assert(result[1].name == "read", "first tool should be read")
  assert(result[1].id == "tool_123", "first tool id mismatch")
  assert(result[2].name == "bash", "second tool should be bash")
end
test_extract_tool_calls_with_tools()

local function test_extract_tool_calls_mixed()
  local response = {
    content = {
      {type = "text", text = "Starting..."},
      {type = "tool_use", id = "t1", name = "read", input = {path = "/a"}},
      {type = "text", text = "Reading..."},
      {type = "tool_use", id = "t2", name = "write", input = {path = "/b", content = "x"}},
      {type = "text", text = "Done"},
    }
  }
  local result = api.extract_tool_calls(response)
  assert(#result == 2, "should extract 2 tool calls from mixed content")
  assert(result[1].id == "t1", "first tool id mismatch")
  assert(result[2].id == "t2", "second tool id mismatch")
end
test_extract_tool_calls_mixed()

print("all api tests passed")
