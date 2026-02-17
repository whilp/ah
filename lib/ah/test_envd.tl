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

-- Roundtrip test: embed env.d alongside other files, verify both survive
local function test_embed_roundtrip()
  local embed_mod = require("cosmic.embed")
  local zip = require("cosmic.zip")

  local tmpdir = fs.mkdtemp(fs.join(TEST_TMPDIR, "envd_roundtrip_XXXXXX"))

  -- copy running exe as base
  local exe_data = cio.slurp(arg[-1] as string)
  assert(exe_data, "should read running executable")
  local out = fs.join(tmpdir, "testbin")
  cio.barf(out, exe_data)

  -- single embed dir with both tools and env.d
  local src = fs.join(tmpdir, "src")
  fs.makedirs(fs.join(src, "embed", "tools"))
  fs.makedirs(fs.join(src, "embed", "env.d"))
  cio.barf(fs.join(src, "embed", "tools", "mytool.lua"), "return {}")
  cio.barf(fs.join(src, "embed", "env.d", "auth.env"), "MY_KEY=secret\n")

  local result = embed_mod.run({src}, out)
  assert(result.ok, "embed should succeed: " .. tostring(result.message))

  -- extract and verify both files present
  local data = cio.slurp(out)
  assert(data, "should read embedded binary")
  local reader = zip.from(data)
  assert(reader, "should parse zip")
  local entries = reader:list()
  local found_tool = false
  local found_envd = false
  for _, name in ipairs(entries) do
    if name == "embed/tools/mytool.lua" then found_tool = true end
    if name == "embed/env.d/auth.env" then found_envd = true end
  end
  reader:close()

  assert(found_tool, "tool should survive embed")
  assert(found_envd, "env.d file should be present")

  fs.rmrf(tmpdir)
  print("PASS test_embed_roundtrip")
end
test_embed_roundtrip()

-- Extract-add-embed roundtrip: extract existing, add env.d, re-embed
local function test_extract_add_embed()
  local embed_mod = require("cosmic.embed")
  local zip = require("cosmic.zip")

  local tmpdir = fs.mkdtemp(fs.join(TEST_TMPDIR, "envd_extract_XXXXXX"))

  -- copy running exe as base
  local exe_data = cio.slurp(arg[-1] as string)
  assert(exe_data, "should read running executable")
  local bin = fs.join(tmpdir, "testbin")
  cio.barf(bin, exe_data)

  -- first: embed a tool
  local src1 = fs.join(tmpdir, "src1")
  fs.makedirs(fs.join(src1, "embed", "tools"))
  cio.barf(fs.join(src1, "embed", "tools", "mytool.lua"), "return {}")
  local r1 = embed_mod.run({src1}, bin)
  assert(r1.ok, "first embed should succeed")

  -- extract into a working dir (simulates `ah extract myconfig`)
  local extracted = fs.join(tmpdir, "myconfig")
  fs.makedirs(extracted)
  local data = cio.slurp(bin)
  local reader = zip.from(data)
  for _, name in ipairs(reader:list()) do
    local prefix = "embed/"
    if name:sub(1, #prefix) == prefix and name:sub(-1) ~= "/" then
      local content = reader:read(name)
      if content then
        local rel = name:sub(#prefix + 1)
        local filepath = fs.join(extracted, rel)
        fs.makedirs(fs.dirname(filepath))
        cio.barf(filepath, content)
      end
    end
  end
  reader:close()

  -- add env.d to the extracted dir
  fs.makedirs(fs.join(extracted, "env.d"))
  cio.barf(fs.join(extracted, "env.d", "auth.env"), "MY_KEY=secret\n")

  -- re-embed (simulates `ah embed myconfig`)
  local src2 = fs.join(tmpdir, "src2")
  fs.makedirs(src2)
  fs.symlink(extracted, fs.join(src2, "embed"))
  local r2 = embed_mod.run({src2}, bin)
  assert(r2.ok, "re-embed should succeed")

  -- verify both tool and env.d survived
  local data2 = cio.slurp(bin)
  local reader2 = zip.from(data2)
  local found_tool = false
  local found_envd = false
  for _, name in ipairs(reader2:list()) do
    if name == "embed/tools/mytool.lua" then found_tool = true end
    if name == "embed/env.d/auth.env" then found_envd = true end
  end
  reader2:close()

  assert(found_tool, "tool should survive extract-add-embed")
  assert(found_envd, "env.d should be present after extract-add-embed")

  fs.rmrf(tmpdir)
  print("PASS test_extract_add_embed")
end
test_extract_add_embed()

print("all envd tests passed")
