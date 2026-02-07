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
  unix.setenv("ANTHROPIC_API_KEY", "test-api-key-123")

  local creds = auth.load_credentials()
  assert(creds, "should load credentials from env")
  assert(creds.access_token == "test-api-key-123", "token mismatch")

  if orig then
    unix.setenv("ANTHROPIC_API_KEY", orig)
  else
    unix.unsetenv("ANTHROPIC_API_KEY")
  end
end
test_load_from_env()

local function test_load_from_env_file()
  local cio = require("cosmic.io")

  local orig_key = os.getenv("ANTHROPIC_API_KEY")
  if orig_key then unix.unsetenv("ANTHROPIC_API_KEY") end

  local tmpdir = os.getenv("TEST_TMPDIR")
  local orig_cwd = unix.getcwd()
  unix.chdir(tmpdir)

  cio.barf(".env", "ANTHROPIC_API_KEY=env-file-key-456\n", tonumber("644", 8))

  local creds = auth.load_credentials()
  assert(creds, "should load credentials from .env file")
  assert(creds.access_token == "env-file-key-456", "token mismatch from .env")

  unix.chdir(orig_cwd)
  if orig_key then unix.setenv("ANTHROPIC_API_KEY", orig_key) end
end
test_load_from_env_file()

print("all auth tests passed")
