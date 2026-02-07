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

local function test_load_from_env_file()
  local cio = require("cosmic.io")

  -- Save and clear env vars
  local orig_key = os.getenv("ANTHROPIC_API_KEY")
  local orig_oauth = os.getenv("CLAUDE_CODE_OAUTH_TOKEN")
  if orig_key then unix.unsetenv("ANTHROPIC_API_KEY") end
  if orig_oauth then unix.unsetenv("CLAUDE_CODE_OAUTH_TOKEN") end

  -- Create .env in temp dir and cd there
  local tmpdir = os.getenv("TEST_TMPDIR")
  local orig_cwd = unix.getcwd()
  unix.chdir(tmpdir)

  cio.barf(".env", "ANTHROPIC_API_KEY=env-file-key-456\n", tonumber("644", 8))

  local creds = auth.load_credentials()
  assert(creds, "should load credentials from .env file")
  assert(creds.access_token == "env-file-key-456", "token mismatch from .env")
  assert(creds.is_api_key, "should be api key")

  -- Restore
  unix.chdir(orig_cwd)
  if orig_key then unix.setenv("ANTHROPIC_API_KEY", orig_key) end
  if orig_oauth then unix.setenv("CLAUDE_CODE_OAUTH_TOKEN", orig_oauth) end
end
test_load_from_env_file()

print("all auth tests passed")
