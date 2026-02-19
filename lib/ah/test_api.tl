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
  assert(req.model == "claude-opus-4-6", "default model should be opus")
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
  -- Non-OAuth system prompt is now an array with cache_control
  local system_arr = req.system as {{string:any}}
  assert(type(req.system) == "table", "system should be array")
  assert(#system_arr == 1, "should have 1 system block")
  assert(system_arr[1].text == "You are a helpful assistant", "should include system prompt text")
  assert(system_arr[1].cache_control ~= nil, "should have cache_control")
  local cc = system_arr[1].cache_control as {string:any}
  assert(cc.type == "ephemeral", "cache_control type should be ephemeral")
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
  -- cache_control should be on the last block (second block)
  assert(system_arr[1].cache_control == nil, "first block should not have cache_control")
  assert(system_arr[2].cache_control ~= nil, "last block should have cache_control")
  local cc = system_arr[2].cache_control as {string:any}
  assert(cc.type == "ephemeral", "cache_control type should be ephemeral")
end
test_build_request_oauth_system_prompt()

local function test_build_request_oauth_no_system_cache()
  -- OAuth mode without system prompt should cache the identity block
  local req = api.build_request({}, {}, true)
  local system_arr = req.system as {{string:any}}
  assert(#system_arr == 1, "should have 1 system block (identity only)")
  assert(system_arr[1].cache_control ~= nil, "identity block should have cache_control when no user system")
  local cc = system_arr[1].cache_control as {string:any}
  assert(cc.type == "ephemeral", "cache_control type should be ephemeral")
end
test_build_request_oauth_no_system_cache()

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
  -- From Retry-After header (seconds) - should return exact ms, no padding
  local headers = {["retry-after"] = "5"}
  local delay = api.extract_retry_delay("", headers)
  assert(delay == 5000, "should parse Retry-After to 5000ms, got: " .. tostring(delay))

  -- From error message pattern "retry in Xs"
  delay = api.extract_retry_delay("Please retry in 10s", {})
  assert(delay == 10000, "should parse 'retry in Xs' to 10000ms, got: " .. tostring(delay))

  -- From error message pattern "retry in Xms"
  delay = api.extract_retry_delay("Please retry in 500ms", {})
  assert(delay == 500, "should parse 'retry in Xms' to 500ms, got: " .. tostring(delay))

  -- From error message pattern "reset after Xs"
  delay = api.extract_retry_delay("Your quota will reset after 30s", {})
  assert(delay == 30000, "should parse 'reset after Xs' to 30000ms, got: " .. tostring(delay))

  -- No delay found
  delay = api.extract_retry_delay("some other error", {})
  assert(delay == nil, "should return nil when no delay found, got: " .. tostring(delay))
end
test_extract_retry_delay()

local function test_resolve_model()
  -- Aliases should resolve to full names
  assert(api.resolve_model("sonnet") == "claude-sonnet-4-6", "sonnet alias")
  assert(api.resolve_model("sonnet-1m") == "claude-sonnet-4-6-1m", "sonnet-1m alias")
  assert(api.resolve_model("opus") == "claude-opus-4-6", "opus alias")
  assert(api.resolve_model("opus-1m") == "claude-opus-4-6-1m", "opus-1m alias")
  assert(api.resolve_model("haiku") == "claude-haiku-4-5-20251001", "haiku alias")
  -- Full names should pass through
  assert(api.resolve_model("claude-sonnet-4-6") == "claude-sonnet-4-6", "full name passthrough")
  assert(api.resolve_model("claude-sonnet-4-6-1m") == "claude-sonnet-4-6-1m", "sonnet 4.6 1m passthrough")
  -- Unknown names should pass through
  assert(api.resolve_model("custom-model") == "custom-model", "unknown passthrough")
  -- Nil should return nil
  assert(api.resolve_model(nil) == nil, "nil returns nil")
end
test_resolve_model()

-- Tests for tool name normalization (OAuth mode)
local function test_to_claude_code_name()
  assert(api.to_claude_code_name("read") == "Read", "read -> Read")
  assert(api.to_claude_code_name("write") == "Write", "write -> Write")
  assert(api.to_claude_code_name("edit") == "Edit", "edit -> Edit")
  assert(api.to_claude_code_name("bash") == "Bash", "bash -> Bash")
  assert(api.to_claude_code_name("custom") == "custom", "unknown names unchanged")
end
test_to_claude_code_name()

local function test_from_claude_code_name()
  assert(api.from_claude_code_name("Read") == "read", "Read -> read")
  assert(api.from_claude_code_name("Write") == "write", "Write -> write")
  assert(api.from_claude_code_name("Edit") == "edit", "Edit -> edit")
  assert(api.from_claude_code_name("Bash") == "bash", "Bash -> bash")
  assert(api.from_claude_code_name("Custom") == "Custom", "unknown names unchanged")
end
test_from_claude_code_name()

local function test_build_request_oauth_tool_names()
  -- OAuth mode should remap tool names in the request
  local tools_list = {
    {name = "read", description = "Read a file", input_schema = {type = "object"}},
    {name = "bash", description = "Run command", input_schema = {type = "object"}},
    {name = "custom", description = "Custom tool", input_schema = {type = "object"}},
  }
  local req = api.build_request({}, {tools = tools_list}, true)
  assert(req.tools ~= nil, "should include tools")
  local req_tools = req.tools as {{string:any}}
  assert(#req_tools == 3, "should have 3 tools")

  -- Built-in tools should be remapped
  assert(req_tools[1].name == "Read", "read should become Read in OAuth mode")
  assert(req_tools[2].name == "Bash", "bash should become Bash in OAuth mode")
  -- Custom tools should pass through unchanged
  assert(req_tools[3].name == "custom", "custom tools should be unchanged")
end
test_build_request_oauth_tool_names()

local function test_build_request_non_oauth_tool_names()
  -- Non-OAuth mode should keep tool names unchanged
  local tools_list = {
    {name = "read", description = "Read a file", input_schema = {type = "object"}},
  }
  local req = api.build_request({}, {tools = tools_list}, false)
  local req_tools = req.tools as {{string:any}}
  assert(req_tools[1].name == "read", "read should stay read in non-OAuth mode")
end
test_build_request_non_oauth_tool_names()

-- Tests for lazy API URL resolution
local env = require("cosmic.env")

local function test_get_api_url_default()
  -- With no ANTHROPIC_BASE_URL set, should return the default
  local saved = os.getenv("ANTHROPIC_BASE_URL")
  env.unset("ANTHROPIC_BASE_URL")
  local url = api.get_api_url()
  assert(url == "https://api.anthropic.com/v1/messages",
    "default API URL should be anthropic, got: " .. url)
  if saved then env.set("ANTHROPIC_BASE_URL", saved) end
  print("PASS test_get_api_url_default")
end
test_get_api_url_default()

local function test_get_api_url_custom()
  -- With ANTHROPIC_BASE_URL set, should use it (stripping trailing slash)
  local saved = os.getenv("ANTHROPIC_BASE_URL")
  env.set("ANTHROPIC_BASE_URL", "http://localhost:8080/")
  local url = api.get_api_url()
  assert(url == "http://localhost:8080/v1/messages",
    "custom API URL should use base, got: " .. url)
  -- Without trailing slash
  env.set("ANTHROPIC_BASE_URL", "http://localhost:9090")
  url = api.get_api_url()
  assert(url == "http://localhost:9090/v1/messages",
    "custom API URL without trailing slash, got: " .. url)
  if saved then env.set("ANTHROPIC_BASE_URL", saved) else env.unset("ANTHROPIC_BASE_URL") end
  print("PASS test_get_api_url_custom")
end
test_get_api_url_custom()

local function test_get_api_url_lazy_after_env_change()
  -- Simulate the envd.load() scenario: env var not set at first, then set later.
  -- get_api_url should reflect the change because it reads lazily.
  local saved = os.getenv("ANTHROPIC_BASE_URL")
  env.unset("ANTHROPIC_BASE_URL")
  local url1 = api.get_api_url()
  assert(url1 == "https://api.anthropic.com/v1/messages", "before envd: default URL")
  -- Simulate envd.load() setting the var
  env.set("ANTHROPIC_BASE_URL", "http://litellm:4000")
  local url2 = api.get_api_url()
  assert(url2 == "http://litellm:4000/v1/messages",
    "after envd: should use new base, got: " .. url2)
  if saved then env.set("ANTHROPIC_BASE_URL", saved) else env.unset("ANTHROPIC_BASE_URL") end
  print("PASS test_get_api_url_lazy_after_env_change")
end
test_get_api_url_lazy_after_env_change()

local function test_get_proxy_url_none()
  -- With no proxy env vars, should return nil
  local saved = {
    os.getenv("https_proxy"), os.getenv("HTTPS_PROXY"),
    os.getenv("http_proxy"), os.getenv("HTTP_PROXY"),
  }
  env.unset("https_proxy")
  env.unset("HTTPS_PROXY")
  env.unset("http_proxy")
  env.unset("HTTP_PROXY")
  local url = api.get_proxy_url()
  assert(url == nil, "no proxy vars should return nil, got: " .. tostring(url))
  -- Restore
  if saved[1] then env.set("https_proxy", saved[1]) end
  if saved[2] then env.set("HTTPS_PROXY", saved[2]) end
  if saved[3] then env.set("http_proxy", saved[3]) end
  if saved[4] then env.set("HTTP_PROXY", saved[4]) end
  print("PASS test_get_proxy_url_none")
end
test_get_proxy_url_none()

print("all api tests passed")
