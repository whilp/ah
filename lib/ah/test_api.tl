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

local function test_build_request_default_model()
  local req = api.build_request({}, {})
  assert(req.model == api.DEFAULT_MODEL, "should use default model")
  assert(req.model == "claude-sonnet-4-20250514", "default model should be sonnet")
end
test_build_request_default_model()

local function test_build_request_custom_model()
  local req = api.build_request({}, {model = "claude-haiku-3-5-20241022"})
  assert(req.model == "claude-haiku-3-5-20241022", "should use custom model")
end
test_build_request_custom_model()

local function test_build_request_nil_model()
  local req = api.build_request({}, {model = nil})
  assert(req.model == api.DEFAULT_MODEL, "nil model should use default")
end
test_build_request_nil_model()

local function test_build_request_with_system()
  local req = api.build_request({}, {system = "You are a helpful assistant"})
  assert(req.system == "You are a helpful assistant", "should include system prompt")
end
test_build_request_with_system()

local function test_build_request_with_tools()
  local tools_list = {{name = "read", description = "Read a file"}}
  local req = api.build_request({}, {tools = tools_list})
  assert(req.tools ~= nil, "should include tools")
  assert(#(req.tools as {any}) == 1, "should have 1 tool")
end
test_build_request_with_tools()

print("all api tests passed")
