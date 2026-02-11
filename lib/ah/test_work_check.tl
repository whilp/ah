#!/usr/bin/env cosmic
-- test_work_check.tl: tests for check phase file loading resilience
--
-- Bug: the check phase reads o/work/plan/plan.md from the filesystem,
-- but the do-phase agent may delete it (e.g. via `make clean` which runs
-- `rm -rf o/`). The fix is to cache plan contents before the do phase
-- and pass them through using load_phase_file.

local record Work
  load_phase_file: function(string, string): string
  build_check_prompt: function(string, string, string): string
  format_protect_dirs: function({string}): string
end

local work = require("ah.work") as Work

-- Test: load_phase_file returns cached content when provided, even if file missing
local function test_load_phase_file_prefers_cache()
  local result = work.load_phase_file("cached plan contents", "/nonexistent/plan.md")
  assert(result == "cached plan contents",
    "should prefer cached content over file, got: " .. tostring(result))
  print("✓ load_phase_file prefers cached content over file")
end
test_load_phase_file_prefers_cache()

-- Test: load_phase_file reads from file when cache is nil
local function test_load_phase_file_reads_file()
  local tmpdir = os.getenv("TEST_TMPDIR")
  if not tmpdir then
    print("✓ load_phase_file_reads_file skipped (no TEST_TMPDIR)")
    return
  end

  local path = tmpdir .. "/plan.md"
  local f = io.open(path, "w")
  f:write("file plan contents")
  f:close()

  local result = work.load_phase_file(nil, path)
  assert(result == "file plan contents",
    "should read from file when no cache, got: " .. tostring(result))
  print("✓ load_phase_file reads from file when no cache")
end
test_load_phase_file_reads_file()

-- Test: load_phase_file returns nil when both cache and file are missing
local function test_load_phase_file_both_missing()
  local result = work.load_phase_file(nil, "/nonexistent/plan.md")
  assert(result == nil, "should return nil when both cache and file are missing")
  print("✓ load_phase_file returns nil when both are missing")
end
test_load_phase_file_both_missing()

-- Test: cached plan contents survive file deletion (simulates the bug scenario)
local function test_cached_plan_survives_deletion()
  local tmpdir = os.getenv("TEST_TMPDIR")
  if not tmpdir then
    print("✓ cached_plan_survives_deletion skipped (no TEST_TMPDIR)")
    return
  end

  -- Write plan.md
  local path = tmpdir .. "/plan.md"
  local f = io.open(path, "w")
  f:write("# Plan\nBranch: work/42\n")
  f:close()

  -- Cache contents (simulates main() reading after phase_plan)
  local cached = work.load_phase_file(nil, path)
  assert(cached ~= nil, "should read plan.md")

  -- Delete file (simulates do agent running make clean)
  os.remove(path)

  -- load_phase_file with cache should still return contents
  local result = work.load_phase_file(cached, path)
  assert(result == "# Plan\nBranch: work/42\n",
    "cached content should survive file deletion, got: " .. tostring(result))

  -- build_check_prompt should work with cached contents
  local template = "Plan:\n{plan.md contents}\n\nDo:\n{do.md contents}"
  local prompt = work.build_check_prompt(template, result, "# Do\nsuccess\n")
  assert(prompt:find("# Plan"), "check prompt should contain cached plan contents")
  assert(not prompt:find("{plan.md contents}"), "template vars should be replaced")

  print("✓ cached plan contents survive file deletion")
end
test_cached_plan_survives_deletion()

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
