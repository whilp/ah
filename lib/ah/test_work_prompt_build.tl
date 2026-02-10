#!/usr/bin/env cosmic
-- test_work_prompt_build.tl: tests for do/check prompt building and error formatting
--
-- These tests demonstrate three bugs observed in the workflow run:
--
-- 1. phase_do/phase_check use raw gsub for interpolation, which crashes
--    when plan contents contain % (a magic character in Lua replacements).
--    The safe interpolate_prompt function exists but isn't used.
--
-- 2. format_run_error ignores stderr, so when gh pr create fails the
--    error message is empty (the real error goes to stderr).
--
-- 3. phase_push ignores git push failure, always returning 0.

local record Work
  build_do_prompt: function(string, string, string, string): string
  build_check_prompt: function(string, string, string): string
  format_run_error: function(string, string, string): string
  interpolate_prompt: function(string, {string:string}): string
end

local work = require("ah.work") as Work

-- Bug 1a: build_do_prompt crashes when plan contents contain %
local function test_do_prompt_percent_in_plan()
  local template = "Title: {title}\nPlan:\n{plan.md contents}\nBranch: {branch}"
  local plan = "increase test coverage to 100%"
  local ok, result = pcall(work.build_do_prompt, template, "fix tests", plan, "work/42")
  assert(ok, "build_do_prompt should not crash with % in plan, got error: " .. tostring(result))
  assert(result == "Title: fix tests\nPlan:\nincrease test coverage to 100%\nBranch: work/42",
    "wrong result: " .. tostring(result))
  print("✓ build_do_prompt handles % in plan contents")
end
test_do_prompt_percent_in_plan()

-- Bug 1b: build_do_prompt crashes when title contains %1 capture ref
local function test_do_prompt_capture_ref_in_title()
  local template = "Title: {title}\nPlan:\n{plan.md contents}\nBranch: {branch}"
  local ok, result = pcall(work.build_do_prompt, template, "fix %1 regex", "plan text", "work/42")
  assert(ok, "build_do_prompt should not crash with %1 in title, got error: " .. tostring(result))
  assert(result == "Title: fix %1 regex\nPlan:\nplan text\nBranch: work/42",
    "wrong result: " .. tostring(result))
  print("✓ build_do_prompt handles %N capture references in title")
end
test_do_prompt_capture_ref_in_title()

-- Bug 1c: build_check_prompt crashes when do contents contain %
local function test_check_prompt_percent_in_do()
  local template = "Plan:\n{plan.md contents}\nDo:\n{do.md contents}"
  local do_contents = "coverage went from 50% to 100%"
  local ok, result = pcall(work.build_check_prompt, template, "the plan", do_contents)
  assert(ok, "build_check_prompt should not crash with % in do contents, got error: " .. tostring(result))
  assert(result == "Plan:\nthe plan\nDo:\ncoverage went from 50% to 100%",
    "wrong result: " .. tostring(result))
  print("✓ build_check_prompt handles % in do contents")
end
test_check_prompt_percent_in_do()

-- Bug 2: format_run_error ignores stderr
local function test_format_error_prefers_stderr()
  -- When a command fails, stderr usually has the real error.
  -- stdout is often empty for failed commands like gh pr create.
  local msg = work.format_run_error("gh pr create failed", nil, "GraphQL: not permitted")
  assert(msg == "gh pr create failed: GraphQL: not permitted",
    "should prefer stderr when stdout is nil, got: " .. msg)
  print("✓ format_run_error prefers stderr over nil stdout")
end
test_format_error_prefers_stderr()

-- Bug 2b: format_run_error should prefer stderr when stdout is empty
local function test_format_error_prefers_stderr_over_empty()
  local msg = work.format_run_error("gh pr create failed", "", "permission denied")
  assert(msg == "gh pr create failed: permission denied",
    "should prefer stderr over empty stdout, got: " .. msg)
  print("✓ format_run_error prefers stderr over empty stdout")
end
test_format_error_prefers_stderr_over_empty()

-- Bug 2c: format_run_error falls back to stdout when no stderr
local function test_format_error_falls_back_to_stdout()
  local msg = work.format_run_error("command failed", "some stdout error", nil)
  assert(msg == "command failed: some stdout error",
    "should use stdout when no stderr, got: " .. msg)
  print("✓ format_run_error falls back to stdout when no stderr")
end
test_format_error_falls_back_to_stdout()

-- Bug 2d: format_run_error handles both nil
local function test_format_error_both_nil()
  local msg = work.format_run_error("command failed", nil, nil)
  assert(msg == "command failed: no output",
    "should say 'no output' when both nil, got: " .. msg)
  print("✓ format_run_error handles both nil")
end
test_format_error_both_nil()

-- Sanity: interpolate_prompt (the safe version) handles all the above
local function test_interpolate_prompt_safe()
  local template = "{title}: {body}"
  local result = work.interpolate_prompt(template, {
    title = "100% coverage",
    body = "fix %1 and %2 refs",
  })
  assert(result == "100% coverage: fix %1 and %2 refs",
    "interpolate_prompt should handle % safely, got: " .. result)
  print("✓ interpolate_prompt handles % safely (reference)")
end
test_interpolate_prompt_safe()

print("\nAll work-prompt-build tests passed!")
