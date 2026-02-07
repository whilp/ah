#!/usr/bin/env cosmic
local unix = require("cosmo.unix")
local auth = require("ah.auth")

local function test_get_auth_headers_api_key()
  local creds: auth.Credentials = {
    access_token = "sk-test-key",
    is_api_key = true,
  }
  local headers = auth.get_auth_headers(creds)
  assert(headers["x-api-key"] == "sk-test-key", "api key header mismatch")
  assert(headers["anthropic-version"] == "2023-06-01", "version header missing")
  assert(headers["content-type"] == "application/json", "content-type missing")
  assert(not headers["Authorization"], "should not have Authorization header")
end
test_get_auth_headers_api_key()

local function test_get_auth_headers_oauth()
  local creds: auth.Credentials = {
    access_token = "ant-oauth-access-test",
  }
  local headers = auth.get_auth_headers(creds)
  assert(headers["Authorization"] == "Bearer ant-oauth-access-test", "auth header mismatch")
  assert(not headers["x-api-key"], "should not have x-api-key header")
end
test_get_auth_headers_oauth()

local function test_load_from_env()
  -- Save original value
  local orig = os.getenv("ANTHROPIC_API_KEY")

  -- Set test key
  unix.setenv("ANTHROPIC_API_KEY", "test-api-key-123")

  -- Clear OAuth token to ensure we fall back to API key
  local orig_oauth = os.getenv("CLAUDE_CODE_OAUTH_TOKEN")
  if orig_oauth then
    unix.unsetenv("CLAUDE_CODE_OAUTH_TOKEN")
  end

  local creds = auth.load_credentials()
  assert(creds, "should load credentials from env")
  assert(creds.access_token == "test-api-key-123", "token mismatch")
  assert(creds.is_api_key, "should be api key")

  -- Restore
  if orig then
    unix.setenv("ANTHROPIC_API_KEY", orig)
  else
    unix.unsetenv("ANTHROPIC_API_KEY")
  end
  if orig_oauth then
    unix.setenv("CLAUDE_CODE_OAUTH_TOKEN", orig_oauth)
  end
end
test_load_from_env()

print("all auth tests passed")
