#!/usr/bin/env cosmic
-- test_envd.tl: tests for env.d loading
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local env = require("cosmic.env")
local envd = require("ah.envd")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR") or "/tmp"

local function test_load_env_dir_basic()
  local dir = fs.join(TEST_TMPDIR, "envd_basic")
  fs.makedirs(dir)
  cio.barf(fs.join(dir, "AH_TEST_FOO"), "hello")
  cio.barf(fs.join(dir, "AH_TEST_BAR"), "world\n")

  -- clear any existing values
  env.unset("AH_TEST_FOO")
  env.unset("AH_TEST_BAR")

  local count = envd.load_env_dir(dir)
  assert(count == 2, "should set 2 vars, got: " .. tostring(count))
  assert(env.get("AH_TEST_FOO") == "hello", "FOO should be hello, got: " .. tostring(env.get("AH_TEST_FOO")))
  assert(env.get("AH_TEST_BAR") == "world", "BAR should be world (trimmed), got: " .. tostring(env.get("AH_TEST_BAR")))

  env.unset("AH_TEST_FOO")
  env.unset("AH_TEST_BAR")
  print("PASS test_load_env_dir_basic")
end
test_load_env_dir_basic()

local function test_load_env_dir_no_overwrite()
  local dir = fs.join(TEST_TMPDIR, "envd_nooverwrite")
  fs.makedirs(dir)
  cio.barf(fs.join(dir, "AH_TEST_EXIST"), "new_value")

  -- set existing value
  env.set("AH_TEST_EXIST", "old_value")

  local count = envd.load_env_dir(dir)
  assert(count == 0, "should set 0 vars (existing not overwritten), got: " .. tostring(count))
  assert(env.get("AH_TEST_EXIST") == "old_value", "should keep old value, got: " .. tostring(env.get("AH_TEST_EXIST")))

  env.unset("AH_TEST_EXIST")
  print("PASS test_load_env_dir_no_overwrite")
end
test_load_env_dir_no_overwrite()

local function test_load_env_dir_skips_dotfiles()
  local dir = fs.join(TEST_TMPDIR, "envd_dotfiles")
  fs.makedirs(dir)
  cio.barf(fs.join(dir, ".hidden"), "secret")
  cio.barf(fs.join(dir, "AH_TEST_VISIBLE"), "visible")

  env.unset("AH_TEST_VISIBLE")

  local count = envd.load_env_dir(dir)
  assert(count == 1, "should set 1 var (skip dotfile), got: " .. tostring(count))
  assert(env.get("AH_TEST_VISIBLE") == "visible", "VISIBLE should be set")
  assert(not env.get(".hidden"), "dotfile should not be set as env var")

  env.unset("AH_TEST_VISIBLE")
  print("PASS test_load_env_dir_skips_dotfiles")
end
test_load_env_dir_skips_dotfiles()

local function test_load_env_dir_skips_invalid_names()
  local dir = fs.join(TEST_TMPDIR, "envd_invalid")
  fs.makedirs(dir)
  cio.barf(fs.join(dir, "invalid-name"), "bad")
  cio.barf(fs.join(dir, "also.bad"), "bad")
  cio.barf(fs.join(dir, "123start"), "bad")
  cio.barf(fs.join(dir, "VALID_NAME"), "good")

  env.unset("VALID_NAME")

  local count = envd.load_env_dir(dir)
  assert(count == 1, "should set 1 var (skip invalid names), got: " .. tostring(count))
  assert(env.get("VALID_NAME") == "good", "VALID_NAME should be set")

  env.unset("VALID_NAME")
  print("PASS test_load_env_dir_skips_invalid_names")
end
test_load_env_dir_skips_invalid_names()

local function test_load_env_dir_skips_empty()
  local dir = fs.join(TEST_TMPDIR, "envd_empty")
  fs.makedirs(dir)
  cio.barf(fs.join(dir, "AH_TEST_EMPTY"), "")
  cio.barf(fs.join(dir, "AH_TEST_WHITESPACE"), "   \n  \n  ")

  env.unset("AH_TEST_EMPTY")
  env.unset("AH_TEST_WHITESPACE")

  local count = envd.load_env_dir(dir)
  assert(count == 0, "should set 0 vars (empty content), got: " .. tostring(count))

  env.unset("AH_TEST_EMPTY")
  env.unset("AH_TEST_WHITESPACE")
  print("PASS test_load_env_dir_skips_empty")
end
test_load_env_dir_skips_empty()

local function test_load_env_dir_missing()
  local count = envd.load_env_dir("/nonexistent/path/env.d")
  assert(count == 0, "missing dir should return 0, got: " .. tostring(count))
  print("PASS test_load_env_dir_missing")
end
test_load_env_dir_missing()

local function test_load_env_dir_multiline_uses_full_content()
  local dir = fs.join(TEST_TMPDIR, "envd_multiline")
  fs.makedirs(dir)
  -- multiline token (e.g. a PEM key) — full content should be preserved
  cio.barf(fs.join(dir, "AH_TEST_MULTI"), "line1\nline2\nline3")

  env.unset("AH_TEST_MULTI")

  local count = envd.load_env_dir(dir)
  assert(count == 1, "should set 1 var, got: " .. tostring(count))
  assert(env.get("AH_TEST_MULTI") == "line1\nline2\nline3", "should preserve multiline content, got: " .. tostring(env.get("AH_TEST_MULTI")))

  env.unset("AH_TEST_MULTI")
  print("PASS test_load_env_dir_multiline_uses_full_content")
end
test_load_env_dir_multiline_uses_full_content()

print("all envd tests passed")
