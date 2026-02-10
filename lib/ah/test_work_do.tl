#!/usr/bin/env cosmic
-- test_work_do.tl: tests for work-do script

local path = require("cosmo.path")

local record WorkDo
  extract_branch: function(string, string): string
end

local script_path = path.join(os.getenv("TEST_BIN") or "bin", "..", "bin", "work-do")
local wd = dofile(script_path) as WorkDo

-- Test extract_branch with explicit branch in plan
local function test_extract_branch_explicit()
  local plan = [[
# Plan

Branch: feature/custom-branch

## Tasks
- Do something
]]
  local branch = wd.extract_branch(plan, "123")
  assert(branch == "feature/custom-branch", "should extract explicit branch, got: " .. branch)
  print("✓ extract_branch extracts explicit branch from plan")
end
test_extract_branch_explicit()

-- Test extract_branch falls back to default
local function test_extract_branch_default()
  local plan = [[
# Plan

## Tasks
- Do something
]]
  local branch = wd.extract_branch(plan, "456")
  assert(branch == "work/456", "should use default branch, got: " .. branch)
  print("✓ extract_branch falls back to work/<number>")
end
test_extract_branch_default()

-- Test extract_branch with branch at different position
local function test_extract_branch_middle()
  local plan = [[
# Plan

Some intro text.

Branch: work/issue-789

More text here.
]]
  local branch = wd.extract_branch(plan, "000")
  assert(branch == "work/issue-789", "should find branch in middle, got: " .. branch)
  print("✓ extract_branch finds branch anywhere in plan")
end
test_extract_branch_middle()

print("\nAll work-do tests passed!")
