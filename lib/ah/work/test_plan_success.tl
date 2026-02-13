-- Test plan phase success logic
-- The plan phase should succeed if plan.md exists, even if the agent
-- subprocess didn't exit cleanly.

local fs = require("cosmic.fs")
local unix = require("cosmo.unix")
local util = require("ah.work.util")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp/test_plan_success"
unix.rmrf(tmpdir)
fs.makedirs(tmpdir)

-- Helper: check if plan output is valid
-- This mirrors the logic we want in phase_plan
local function is_plan_valid(plan_dir: string): boolean
  local content = util.read_file(plan_dir .. "/plan.md")
  if not content then return false end
  if #content == 0 then return false end
  return true
end

-- Test case 1: plan.md exists and has content -> valid
print("Test 1: plan.md exists with content")
local plan_dir = tmpdir .. "/plan"
fs.makedirs(plan_dir)
local f = io.open(plan_dir .. "/plan.md", "w")
if f then
  f:write("# Plan\n\nThis is a complete plan.\n")
  f:close()
end
assert(is_plan_valid(plan_dir), "plan with content should be valid")
print("  ✓ plan with content is valid")

-- Test case 2: plan.md doesn't exist -> invalid
print("Test 2: plan.md doesn't exist")
local empty_dir = tmpdir .. "/empty"
fs.makedirs(empty_dir)
assert(not is_plan_valid(empty_dir), "missing plan should be invalid")
print("  ✓ missing plan.md is invalid")

-- Test case 3: plan.md is empty -> invalid
print("Test 3: plan.md is empty")
local empty_plan_dir = tmpdir .. "/empty_plan"
fs.makedirs(empty_plan_dir)
f = io.open(empty_plan_dir .. "/plan.md", "w")
if f then
  f:write("")
  f:close()
end
assert(not is_plan_valid(empty_plan_dir), "empty plan should be invalid")
print("  ✓ empty plan.md is invalid")

-- Cleanup
unix.rmrf(tmpdir)

print("\nAll tests passed!")
