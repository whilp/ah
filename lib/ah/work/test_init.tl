#!/usr/bin/env cosmic
-- test_init.tl: tests for ah.work CLI/main

local record Work
  main: function({string}): integer
end

local work = require("ah.work") as Work

-- Test that help returns 0
local function test_help()
  local rc = work.main({"-h"})
  assert(rc == 0, "help should return 0")
  print("✓ -h returns 0")
end
test_help()

-- Test that --help returns 0
local function test_long_help()
  local rc = work.main({"--help"})
  assert(rc == 0, "--help should return 0")
  print("✓ --help returns 0")
end
test_long_help()

-- Test that no args (no repo) returns 1
local function test_no_args()
  local rc = work.main({"--no-sandbox"})
  assert(rc == 1, "no args should return 1, got: " .. tostring(rc))
  print("✓ no args returns 1 (missing repo)")
end
test_no_args()

-- Test subcommand plan --help returns 0
local function test_plan_help()
  local rc = work.main({"--no-sandbox", "plan", "--help"})
  assert(rc == 0, "plan --help should return 0")
  print("✓ plan --help returns 0")
end
test_plan_help()

-- Test subcommand plan without required args returns 1
local function test_plan_no_args()
  local rc = work.main({"--no-sandbox", "plan"})
  assert(rc == 1, "plan without --repo should return 1, got: " .. tostring(rc))
  print("✓ plan without --repo returns 1")
end
test_plan_no_args()

-- Test subcommand do --help returns 0
local function test_do_help()
  local rc = work.main({"--no-sandbox", "do", "--help"})
  assert(rc == 0, "do --help should return 0")
  print("✓ do --help returns 0")
end
test_do_help()

-- Test subcommand do without required args returns 1
local function test_do_no_args()
  local rc = work.main({"--no-sandbox", "do"})
  assert(rc == 1, "do without --title/--number should return 1, got: " .. tostring(rc))
  print("✓ do without --title/--number returns 1")
end
test_do_no_args()

-- Test subcommand act --help returns 0
local function test_act_help()
  local rc = work.main({"--no-sandbox", "act", "--help"})
  assert(rc == 0, "act --help should return 0")
  print("✓ act --help returns 0")
end
test_act_help()

-- Test subcommand act without required args returns 1
local function test_act_no_args()
  local rc = work.main({"--no-sandbox", "act"})
  assert(rc == 1, "act without --issue-url should return 1, got: " .. tostring(rc))
  print("✓ act without --issue-url returns 1")
end
test_act_no_args()

-- Test that o/work/ directory is created even when no issues
local function test_work_dir_always_created()
  local fs = require("cosmic.fs")
  local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
  local workdir = tmpdir .. "/test-work-dir"
  
  -- Clean up any previous run
  os.execute("rm -rf " .. workdir)
  fs.makedirs(workdir)
  
  -- Change to workdir so o/work gets created there
  local original_cwd = fs.getcwd()
  fs.chdir(workdir)
  
  -- Run work with a non-existent repo (will fail to fetch issues)
  -- Using --no-sandbox to avoid network requirements
  local rc = work.main({"--no-sandbox", "--repo", "test/nonexistent"})
  
  -- Should have created o/work/summary.json even though no issues found
  local summary_path = workdir .. "/o/work/summary.json"
  local f = io.open(summary_path, "r")
  
  fs.chdir(original_cwd)
  
  assert(f ~= nil, "o/work/summary.json should exist even when no issues found")
  if f then
    local content = f:read("*a")
    f:close()
    assert(content:find('"status"'), "summary.json should contain status field")
  end
  
  print("✓ o/work/summary.json created even when no issues")
end
test_work_dir_always_created()

print("\nAll work tests passed!")
