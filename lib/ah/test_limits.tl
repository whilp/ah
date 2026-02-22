#!/usr/bin/env cosmic
local cenv = require("cosmic.env")
local limits = require("ah.limits")

-- Test fmt_num helper
local function test_fmt_num()
  assert(limits.fmt_num(0) == "0", "zero")
  assert(limits.fmt_num(999) == "999", "three digits")
  assert(limits.fmt_num(1000) == "1,000", "four digits")
  assert(limits.fmt_num(2100) == "2,100", "2100")
  assert(limits.fmt_num(50000) == "50,000", "50000")
  assert(limits.fmt_num(1000000) == "1,000,000", "million")
end
test_fmt_num()

-- Test fmt_window helper
local function test_fmt_window()
  local line = limits.fmt_window("5h window:", 2100, 5000)
  assert(line:match("42%%"), "expected 42%, got: " .. line)
  assert(line:match("2,100"), "expected 2,100, got: " .. line)
  assert(line:match("5,000"), "expected 5,000, got: " .. line)
end
test_fmt_window()

local function test_fmt_window_zero_limit()
  local line = limits.fmt_window("5h window:", 0, 0)
  assert(line:match("0%%"), "expected 0%, got: " .. line)
end
test_fmt_window_zero_limit()

local function test_fmt_window_nil_fields()
  local line = limits.fmt_window("7d window:", nil, nil)
  assert(line:match("unknown"), "expected unknown, got: " .. line)
end
test_fmt_window_nil_fields()

-- Test cmd_limits returns 1 when no credentials
local function test_cmd_limits_no_creds()
  local orig_key = os.getenv("ANTHROPIC_API_KEY")
  local orig_oauth = os.getenv("CLAUDE_CODE_OAUTH_TOKEN")
  local orig_auth = os.getenv("ANTHROPIC_AUTH_TOKEN")

  if orig_key then cenv.unset("ANTHROPIC_API_KEY") end
  if orig_oauth then cenv.unset("CLAUDE_CODE_OAUTH_TOKEN") end
  if orig_auth then cenv.unset("ANTHROPIC_AUTH_TOKEN") end

  local rc = limits.cmd_limits()
  assert(rc == 1, "expected exit code 1 with no credentials, got " .. tostring(rc))

  if orig_key then cenv.set("ANTHROPIC_API_KEY", orig_key, true) end
  if orig_oauth then cenv.set("CLAUDE_CODE_OAUTH_TOKEN", orig_oauth, true) end
  if orig_auth then cenv.set("ANTHROPIC_AUTH_TOKEN", orig_auth, true) end
end
test_cmd_limits_no_creds()

-- Test cmd_limits returns 1 when using API key (not OAuth)
local function test_cmd_limits_api_key_rejected()
  local orig_key = os.getenv("ANTHROPIC_API_KEY")
  local orig_oauth = os.getenv("CLAUDE_CODE_OAUTH_TOKEN")
  local orig_auth = os.getenv("ANTHROPIC_AUTH_TOKEN")

  if orig_oauth then cenv.unset("CLAUDE_CODE_OAUTH_TOKEN") end
  if orig_auth then cenv.unset("ANTHROPIC_AUTH_TOKEN") end
  cenv.set("ANTHROPIC_API_KEY", "sk-ant-api-test", true)

  local rc = limits.cmd_limits()
  assert(rc == 1, "expected exit code 1 with API key, got " .. tostring(rc))

  if orig_key then cenv.set("ANTHROPIC_API_KEY", orig_key, true)
  else cenv.unset("ANTHROPIC_API_KEY") end
  if orig_oauth then cenv.set("CLAUDE_CODE_OAUTH_TOKEN", orig_oauth, true) end
  if orig_auth then cenv.set("ANTHROPIC_AUTH_TOKEN", orig_auth, true) end
end
test_cmd_limits_api_key_rejected()

print("all limits tests passed")
