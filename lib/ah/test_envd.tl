#!/usr/bin/env cosmic
-- test_envd.tl: tests for env.d loading via cosmic.envd
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local env = require("cosmic.env")
local envd = require("cosmic.envd")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR") or "/tmp"

local function test_load_dir_basic()
  local dir = fs.join(TEST_TMPDIR, "envd_basic")
  fs.makedirs(dir)
  cio.barf(fs.join(dir, "vars.env"), "AH_TEST_FOO=hello\nAH_TEST_BAR=world\n")

  env.unset("AH_TEST_FOO")
  env.unset("AH_TEST_BAR")

  local result = envd.load_dir(dir) as {string:any}
  assert((result.count as integer) == 2, "should set 2 vars, got: " .. tostring(result.count))
  assert(env.get("AH_TEST_FOO") == "hello", "FOO should be hello, got: " .. tostring(env.get("AH_TEST_FOO")))
  assert(env.get("AH_TEST_BAR") == "world", "BAR should be world, got: " .. tostring(env.get("AH_TEST_BAR")))

  env.unset("AH_TEST_FOO")
  env.unset("AH_TEST_BAR")
  print("PASS test_load_dir_basic")
end
test_load_dir_basic()

local function test_load_dir_no_overwrite()
  local dir = fs.join(TEST_TMPDIR, "envd_nooverwrite")
  fs.makedirs(dir)
  cio.barf(fs.join(dir, "vars.env"), "AH_TEST_EXIST=new_value\nAH_TEST_FRESH=brand_new\n")

  env.set("AH_TEST_EXIST", "old_value")
  env.unset("AH_TEST_FRESH")

  local result = envd.load_dir(dir) as {string:any}
  assert((result.count as integer) == 1, "should set 1 var (existing not overwritten), got: " .. tostring(result.count))
  assert(env.get("AH_TEST_EXIST") == "old_value", "should keep old value, got: " .. tostring(env.get("AH_TEST_EXIST")))
  assert(env.get("AH_TEST_FRESH") == "brand_new", "fresh var should be set")

  env.unset("AH_TEST_EXIST")
  env.unset("AH_TEST_FRESH")
  print("PASS test_load_dir_no_overwrite")
end
test_load_dir_no_overwrite()

local function test_load_dir_comments()
  local dir = fs.join(TEST_TMPDIR, "envd_comments")
  fs.makedirs(dir)
  cio.barf(fs.join(dir, "vars.env"), "# a comment\nAH_TEST_COMMENTED=value\n")

  env.unset("AH_TEST_COMMENTED")

  local result = envd.load_dir(dir) as {string:any}
  assert((result.count as integer) == 1, "should set 1 var, got: " .. tostring(result.count))
  assert(env.get("AH_TEST_COMMENTED") == "value", "should set value, got: " .. tostring(env.get("AH_TEST_COMMENTED")))

  env.unset("AH_TEST_COMMENTED")
  print("PASS test_load_dir_comments")
end
test_load_dir_comments()

local function test_load_dir_missing()
  local result = envd.load_dir("/nonexistent/path/env.d") as {string:any}
  assert((result.count as integer) == 0, "missing dir should return count 0, got: " .. tostring(result.count))
  print("PASS test_load_dir_missing")
end
test_load_dir_missing()

local function test_load_embedded()
  -- load() reads /zip/embed/env.d/ which is empty in test context
  local result = envd.load() as {string:any}
  assert((result.count as integer) == 0, "embedded env.d should be empty in tests, got: " .. tostring(result.count))
  assert((result.source as string) == "/zip/embed/env.d", "source should be /zip/embed/env.d, got: " .. tostring(result.source))
  print("PASS test_load_embedded")
end
test_load_embedded()

local function test_load_dir_multiple_files()
  local dir = fs.join(TEST_TMPDIR, "envd_multi")
  fs.makedirs(dir)
  cio.barf(fs.join(dir, "auth.env"), "AH_TEST_KEY=secret\n")
  cio.barf(fs.join(dir, "config.env"), "AH_TEST_CFG=value\n")

  env.unset("AH_TEST_KEY")
  env.unset("AH_TEST_CFG")

  local result = envd.load_dir(dir) as {string:any}
  assert((result.count as integer) == 2, "should set 2 vars from multiple files, got: " .. tostring(result.count))
  assert(env.get("AH_TEST_KEY") == "secret", "KEY should be set")
  assert(env.get("AH_TEST_CFG") == "value", "CFG should be set")

  env.unset("AH_TEST_KEY")
  env.unset("AH_TEST_CFG")
  print("PASS test_load_dir_multiple_files")
end
test_load_dir_multiple_files()

print("all envd tests passed")
