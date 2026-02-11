#!/usr/bin/env cosmic
-- test_work_check.tl: tests for check phase sandbox protection
--
-- Bug: the do-phase agent may delete o/work/plan/ (e.g. via `make clean`
-- which runs `rm -rf o/`). The fix uses unveil to make earlier phase
-- directories read-only via AH_PROTECT_DIRS.

local record Work
  format_protect_dirs: function({string}): string
end

local work = require("ah.work") as Work

-- Test: format_protect_dirs joins paths with colons
local function test_format_protect_dirs_single()
  local result = work.format_protect_dirs({"o/work/plan"})
  assert(result == "o/work/plan",
    "single dir should format as-is, got: " .. tostring(result))
  print("✓ format_protect_dirs handles single directory")
end
test_format_protect_dirs_single()

local function test_format_protect_dirs_multiple()
  local result = work.format_protect_dirs({"o/work/plan", "o/work/do"})
  assert(result == "o/work/plan:o/work/do",
    "multiple dirs should be colon-separated, got: " .. tostring(result))
  print("✓ format_protect_dirs handles multiple directories")
end
test_format_protect_dirs_multiple()

local function test_format_protect_dirs_empty()
  local result = work.format_protect_dirs({})
  assert(result == nil, "empty list should return nil, got: " .. tostring(result))
  print("✓ format_protect_dirs returns nil for empty list")
end
test_format_protect_dirs_empty()

local function test_format_protect_dirs_nil()
  local result = work.format_protect_dirs(nil)
  assert(result == nil, "nil should return nil, got: " .. tostring(result))
  print("✓ format_protect_dirs returns nil for nil input")
end
test_format_protect_dirs_nil()

print("\nAll work-check tests passed!")
