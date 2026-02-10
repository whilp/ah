#!/usr/bin/env cosmic
-- test_work.tl: tests for unified work script

local path = require("cosmo.path")

local record Work
  main: function({string}): integer
  slice: function({string}, integer): {string}
end

local script_path = path.join(os.getenv("TEST_BIN") or "bin", "..", "bin", "work")
local w = dofile(script_path) as Work

-- Test slice helper
local function test_slice()
  local t = {"a", "b", "c", "d"}
  local s = w.slice(t, 2)
  assert(#s == 3, "slice from 2 should have 3 elements, got: " .. #s)
  assert(s[1] == "b", "first element should be b")
  assert(s[2] == "c", "second element should be c")
  assert(s[3] == "d", "third element should be d")
  print("✓ slice works correctly")
end
test_slice()

-- Test slice with start beyond length
local function test_slice_empty()
  local t = {"a", "b"}
  local s = w.slice(t, 5)
  assert(#s == 0, "slice beyond length should be empty")
  print("✓ slice returns empty for out-of-range start")
end
test_slice_empty()

-- Test that help returns 0
local function test_help()
  local rc = w.main({"-h"})
  assert(rc == 0, "help should return 0")
  print("✓ -h returns 0")
end
test_help()

-- Test that --help returns 0
local function test_long_help()
  local rc = w.main({"--help"})
  assert(rc == 0, "--help should return 0")
  print("✓ --help returns 0")
end
test_long_help()

-- Test that no args (no repo) returns 1
local function test_no_args()
  local rc = w.main({})
  assert(rc == 1, "no args should return 1, got: " .. tostring(rc))
  print("✓ no args returns 1 (missing repo)")
end
test_no_args()

-- Test subcommand plan --help returns 0
local function test_plan_help()
  local rc = w.main({"plan", "--help"})
  assert(rc == 0, "plan --help should return 0")
  print("✓ plan --help returns 0")
end
test_plan_help()

-- Test subcommand plan without required args returns 1
local function test_plan_no_args()
  local rc = w.main({"plan"})
  assert(rc == 1, "plan without --repo should return 1, got: " .. tostring(rc))
  print("✓ plan without --repo returns 1")
end
test_plan_no_args()

-- Test subcommand do --help returns 0
local function test_do_help()
  local rc = w.main({"do", "--help"})
  assert(rc == 0, "do --help should return 0")
  print("✓ do --help returns 0")
end
test_do_help()

-- Test subcommand do without required args returns 1
local function test_do_no_args()
  local rc = w.main({"do"})
  assert(rc == 1, "do without --title/--number should return 1, got: " .. tostring(rc))
  print("✓ do without --title/--number returns 1")
end
test_do_no_args()

-- Test subcommand act --help returns 0
local function test_act_help()
  local rc = w.main({"act", "--help"})
  assert(rc == 0, "act --help should return 0")
  print("✓ act --help returns 0")
end
test_act_help()

-- Test subcommand act without required args returns 1
local function test_act_no_args()
  local rc = w.main({"act"})
  assert(rc == 1, "act without --issue-url should return 1, got: " .. tostring(rc))
  print("✓ act without --issue-url returns 1")
end
test_act_no_args()

print("\nAll work tests passed!")
