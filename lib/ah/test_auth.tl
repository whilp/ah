#!/usr/bin/env cosmic
local unix = require("cosmo.unix")
local auth = require("ah.auth")

local function test_get_auth_headers()
  local creds: auth.Credentials = {access_token = "sk-test-key"}
  local headers = auth.get_auth_headers(creds)
  assert(headers["x-api-key"] == "sk-test-key", "api key header mismatch")
  assert(headers["anthropic-version"] == "2023-06-01", "version header missing")
  assert(headers["content-type"] == "application/json", "content-type missing")
end
test_get_auth_headers()

local function test_load_from_env()
  local orig = os.getenv("ANTHROPIC_API_KEY")
  local orig_oauth = os.getenv("CLAUDE_CODE_OAUTH_TOKEN")

  -- Clear OAuth token so ANTHROPIC_API_KEY is used
  if orig_oauth then unix.unsetenv("CLAUDE_CODE_OAUTH_TOKEN") end
  unix.setenv("ANTHROPIC_API_KEY", "test-api-key-123")

  local creds = auth.load_credentials()
  assert(creds, "should load credentials from env")
  assert(creds.access_token == "test-api-key-123", "token mismatch")
  assert(creds.is_oauth == false, "should not be oauth")

  if orig then
    unix.setenv("ANTHROPIC_API_KEY", orig)
  else
    unix.unsetenv("ANTHROPIC_API_KEY")
  end
  if orig_oauth then unix.setenv("CLAUDE_CODE_OAUTH_TOKEN", orig_oauth) end
end
test_load_from_env()

local function test_load_from_env_file()
  local cio = require("cosmic.io")

  local orig_key = os.getenv("ANTHROPIC_API_KEY")
  local orig_oauth = os.getenv("CLAUDE_CODE_OAUTH_TOKEN")

  -- Clear both env vars so .env file is used
  if orig_key then unix.unsetenv("ANTHROPIC_API_KEY") end
  if orig_oauth then unix.unsetenv("CLAUDE_CODE_OAUTH_TOKEN") end

  local tmpdir = os.getenv("TEST_TMPDIR")
  local orig_cwd = unix.getcwd()
  unix.chdir(tmpdir)

  cio.barf(".env", "ANTHROPIC_API_KEY=env-file-key-456\n", tonumber("644", 8))

  local creds = auth.load_credentials()
  assert(creds, "should load credentials from .env file")
  assert(creds.access_token == "env-file-key-456", "token mismatch from .env")
  assert(creds.is_oauth == false, "should not be oauth from .env")

  unix.chdir(orig_cwd)
  if orig_key then unix.setenv("ANTHROPIC_API_KEY", orig_key) end
  if orig_oauth then unix.setenv("CLAUDE_CODE_OAUTH_TOKEN", orig_oauth) end
end
test_load_from_env_file()

local function test_load_oauth_token()
  local orig_key = os.getenv("ANTHROPIC_API_KEY")
  local orig_oauth = os.getenv("CLAUDE_CODE_OAUTH_TOKEN")

  -- Set OAuth token - should take priority
  unix.setenv("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat-test-token")
  unix.setenv("ANTHROPIC_API_KEY", "test-api-key-123")

  local creds = auth.load_credentials()
  assert(creds, "should load credentials from oauth env")
  assert(creds.access_token == "sk-ant-oat-test-token", "should use oauth token")
  assert(creds.is_oauth == true, "should be oauth")

  -- Restore original values
  if orig_key then
    unix.setenv("ANTHROPIC_API_KEY", orig_key)
  else
    unix.unsetenv("ANTHROPIC_API_KEY")
  end
  if orig_oauth then
    unix.setenv("CLAUDE_CODE_OAUTH_TOKEN", orig_oauth)
  else
    unix.unsetenv("CLAUDE_CODE_OAUTH_TOKEN")
  end
end
test_load_oauth_token()

local function test_oauth_headers()
  local creds: auth.Credentials = {access_token = "sk-ant-oat-test", is_oauth = true}
  local headers = auth.get_auth_headers(creds)
  assert(headers["authorization"] == "Bearer sk-ant-oat-test", "oauth should use bearer auth")
  assert(headers["anthropic-beta"]:match("oauth"), "oauth should include beta header")
  assert(headers["x-api-key"] == nil, "oauth should not have x-api-key")
end
test_oauth_headers()

-- Token sanitization: tokens from env vars may contain trailing
-- whitespace or control characters that are invalid in HTTP headers.
-- cosmic.fetch rejects header values containing bytes in 0x00-0x08,
-- 0x0A-0x1F, 0x7F, or 0x80-0x9F (Latin-1 C1 controls).

local function test_oauth_token_trailing_newline()
  local orig_key = os.getenv("ANTHROPIC_API_KEY")
  local orig_oauth = os.getenv("CLAUDE_CODE_OAUTH_TOKEN")

  if orig_key then unix.unsetenv("ANTHROPIC_API_KEY") end
  -- Token with trailing newline (common copy/paste artifact)
  unix.setenv("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat-test-token\n")

  local creds = auth.load_credentials()
  assert(creds, "should load credentials")
  assert(creds.access_token == "sk-ant-oat-test-token",
    "should trim trailing newline, got: [" .. creds.access_token .. "]")

  if orig_key then unix.setenv("ANTHROPIC_API_KEY", orig_key) end
  if orig_oauth then unix.setenv("CLAUDE_CODE_OAUTH_TOKEN", orig_oauth)
  else unix.unsetenv("CLAUDE_CODE_OAUTH_TOKEN") end
end
test_oauth_token_trailing_newline()

local function test_api_key_trailing_whitespace()
  local orig_key = os.getenv("ANTHROPIC_API_KEY")
  local orig_oauth = os.getenv("CLAUDE_CODE_OAUTH_TOKEN")

  if orig_oauth then unix.unsetenv("CLAUDE_CODE_OAUTH_TOKEN") end
  -- Token with trailing spaces and newline
  unix.setenv("ANTHROPIC_API_KEY", "  sk-test-key-456  \n")

  local creds = auth.load_credentials()
  assert(creds, "should load credentials")
  assert(creds.access_token == "sk-test-key-456",
    "should trim whitespace, got: [" .. creds.access_token .. "]")

  if orig_key then unix.setenv("ANTHROPIC_API_KEY", orig_key)
  else unix.unsetenv("ANTHROPIC_API_KEY") end
  if orig_oauth then unix.setenv("CLAUDE_CODE_OAUTH_TOKEN", orig_oauth) end
end
test_api_key_trailing_whitespace()

local function test_oauth_token_crlf()
  local orig_key = os.getenv("ANTHROPIC_API_KEY")
  local orig_oauth = os.getenv("CLAUDE_CODE_OAUTH_TOKEN")

  if orig_key then unix.unsetenv("ANTHROPIC_API_KEY") end
  unix.setenv("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat-test\r\n")

  local creds = auth.load_credentials()
  assert(creds, "should load credentials")
  assert(creds.access_token == "sk-ant-oat-test",
    "should trim CRLF, got: [" .. creds.access_token .. "]")

  if orig_key then unix.setenv("ANTHROPIC_API_KEY", orig_key) end
  if orig_oauth then unix.setenv("CLAUDE_CODE_OAUTH_TOKEN", orig_oauth)
  else unix.unsetenv("CLAUDE_CODE_OAUTH_TOKEN") end
end
test_oauth_token_crlf()

local function test_whitespace_only_token_rejected()
  local orig_key = os.getenv("ANTHROPIC_API_KEY")
  local orig_oauth = os.getenv("CLAUDE_CODE_OAUTH_TOKEN")

  if orig_key then unix.unsetenv("ANTHROPIC_API_KEY") end
  unix.setenv("CLAUDE_CODE_OAUTH_TOKEN", "  \n\r  ")

  local creds, err = auth.load_credentials()
  assert(creds == nil, "whitespace-only token should be rejected")
  assert(err, "should return error message")

  if orig_key then unix.setenv("ANTHROPIC_API_KEY", orig_key) end
  if orig_oauth then unix.setenv("CLAUDE_CODE_OAUTH_TOKEN", orig_oauth)
  else unix.unsetenv("CLAUDE_CODE_OAUTH_TOKEN") end
end
test_whitespace_only_token_rejected()

local function test_oauth_header_value_no_control_chars()
  -- Ensure the authorization header value contains no control characters
  local creds: auth.Credentials = {access_token = "sk-ant-oat-test", is_oauth = true}
  local headers = auth.get_auth_headers(creds)
  local auth_val = headers["authorization"]
  for i = 1, #auth_val do
    local b = auth_val:byte(i)
    -- Valid: TAB(0x09), SP-TILDE(0x20-0x7E), obs-text(0xA0-0xFF)
    local valid = b == 0x09 or (b >= 0x20 and b <= 0x7E) or (b >= 0xA0)
    assert(valid, string.format("auth header contains invalid byte 0x%02X at position %d", b, i))
  end
end
test_oauth_header_value_no_control_chars()

print("all auth tests passed")
