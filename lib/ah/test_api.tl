#!/usr/bin/env cosmic
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
  local req = api.build_request({}, {}, false)
  assert(req.model == api.DEFAULT_MODEL, "should use default model")
  assert(req.model == "claude-sonnet-4-20250514", "default model should be sonnet")
end
test_build_request_default_model()

local function test_build_request_custom_model()
  local req = api.build_request({}, {model = "claude-haiku-3-5-20241022"}, false)
  assert(req.model == "claude-haiku-3-5-20241022", "should use custom model")
end
test_build_request_custom_model()

local function test_build_request_nil_model()
  local req = api.build_request({}, {model = nil}, false)
  assert(req.model == api.DEFAULT_MODEL, "nil model should use default")
end
test_build_request_nil_model()

local function test_build_request_with_system()
  local req = api.build_request({}, {system = "You are a helpful assistant"}, false)
  assert(req.system == "You are a helpful assistant", "should include system prompt")
end
test_build_request_with_system()

local function test_build_request_with_tools()
  local tools_list = {{name = "read", description = "Read a file"}}
  local req = api.build_request({}, {tools = tools_list}, false)
  assert(req.tools ~= nil, "should include tools")
  assert(#(req.tools as {any}) == 1, "should have 1 tool")
end
test_build_request_with_tools()

local function test_build_request_oauth_system_prompt()
  -- OAuth mode should format system as array with Claude Code identity first
  local req = api.build_request({}, {system = "Custom prompt"}, true)
  assert(type(req.system) == "table", "oauth system should be array")
  local system_arr = req.system as {{string:any}}
  assert(#system_arr == 2, "should have 2 system blocks")
  assert((system_arr[1].text as string):match("Claude Code"), "first block should be Claude Code identity")
  assert(system_arr[2].text == "Custom prompt", "second block should be custom prompt")
end
test_build_request_oauth_system_prompt()

-- Tests for parse_api_error
local function test_parse_api_error_rate_limit()
  local body = '{"type":"error","error":{"type":"rate_limit_error","message":"Rate limit exceeded"}}'
  local err = api.parse_api_error(429, body)
  assert(err == "API error 429: Rate limit exceeded", "should extract message, got: " .. err)
end
test_parse_api_error_rate_limit()

local function test_parse_api_error_invalid_request()
  local body = '{"type":"error","error":{"type":"invalid_request_error","message":"Invalid model specified"}}'
  local err = api.parse_api_error(400, body)
  assert(err:match("400"), "should include status code")
  assert(err:match("Invalid model specified"), "should include error message")
end
test_parse_api_error_invalid_request()

local function test_parse_api_error_plain_text()
  local err = api.parse_api_error(500, "Internal Server Error")
  assert(err:match("500"), "should include status code")
  assert(err:match("Internal Server Error"), "should include body as fallback")
end
test_parse_api_error_plain_text()

local function test_parse_api_error_empty_body()
  local err = api.parse_api_error(503, "")
  assert(err:match("503"), "should include status code")
end
test_parse_api_error_empty_body()

local function test_parse_api_error_nil_body()
  local err = api.parse_api_error(502, nil)
  assert(err:match("502"), "should include status code")
end
test_parse_api_error_nil_body()

local function test_parse_api_error_malformed_json()
  local body = '{"type":"error","error":{'  -- incomplete JSON
  local err = api.parse_api_error(400, body)
  assert(err:match("400"), "should include status code")
  -- Should fall back to raw body
end
test_parse_api_error_malformed_json()

-- Tests for retry behavior on 429 errors
local function test_is_retryable_error()
  -- 429 should be retryable
  assert(api.is_retryable_error(429, "rate limit"), "429 should be retryable")
  -- 500 errors should be retryable
  assert(api.is_retryable_error(500, "internal error"), "500 should be retryable")
  assert(api.is_retryable_error(502, "bad gateway"), "502 should be retryable")
  assert(api.is_retryable_error(503, "unavailable"), "503 should be retryable")
  assert(api.is_retryable_error(504, "timeout"), "504 should be retryable")
  -- 400 errors should not be retryable
  assert(not api.is_retryable_error(400, "bad request"), "400 should not be retryable")
  assert(not api.is_retryable_error(401, "unauthorized"), "401 should not be retryable")
  -- Rate limit text should make it retryable
  assert(api.is_retryable_error(200, "rate limit exceeded"), "rate limit text should be retryable")
  assert(api.is_retryable_error(200, "overloaded"), "overloaded text should be retryable")
end
test_is_retryable_error()

local function test_extract_retry_delay()
  -- From Retry-After header (seconds)
  local headers = {["retry-after"] = "5"}
  local delay = api.extract_retry_delay("", headers)
  assert(delay and delay >= 5000, "should parse Retry-After seconds, got: " .. tostring(delay))

  -- From error message pattern "retry in Xs"
  delay = api.extract_retry_delay("Please retry in 10s", {})
  assert(delay and delay >= 10000, "should parse 'retry in Xs' pattern, got: " .. tostring(delay))

  -- From error message pattern "reset after Xs"
  delay = api.extract_retry_delay("Your quota will reset after 30s", {})
  assert(delay and delay >= 30000, "should parse 'reset after Xs' pattern, got: " .. tostring(delay))
end
test_extract_retry_delay()

local function test_resolve_model()
  -- Aliases should resolve to full names
  assert(api.resolve_model("sonnet") == "claude-sonnet-4-20250514", "sonnet alias")
  assert(api.resolve_model("opus") == "claude-opus-4-20250514", "opus alias")
  assert(api.resolve_model("haiku") == "claude-haiku-3-20250314", "haiku alias")
  -- Full names should pass through
  assert(api.resolve_model("claude-sonnet-4-20250514") == "claude-sonnet-4-20250514", "full name passthrough")
  -- Unknown names should pass through
  assert(api.resolve_model("custom-model") == "custom-model", "unknown passthrough")
  -- Nil should return nil
  assert(api.resolve_model(nil) == nil, "nil returns nil")
end
test_resolve_model()

print("all api tests passed")
