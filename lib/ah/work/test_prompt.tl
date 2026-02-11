#!/usr/bin/env cosmic
-- test_prompt.tl: tests for ah.work.prompt module

local record WorkPrompt
  interpolate_prompt: function(string, {string:string}): string
  plan_diagnostic: function(string): string
  build_do_prompt: function(string, string, string, string): string
  build_check_prompt: function(string, string, string): string
  build_fix_prompt: function(string, string, string, string, string): string
  build_friction_prompt: function(string, string): string
end

local prompt = require("ah.work.prompt") as WorkPrompt

-- Test basic interpolation
local function test_interpolate_basic()
  local template = "Plan for {title}\n\n{body}\n\nBranch: work/{issue_number}"
  local result = prompt.interpolate_prompt(template, {
    title = "fix bug",
    body = "the bug is bad",
    issue_number = "42",
  })
  assert(result == "Plan for fix bug\n\nthe bug is bad\n\nBranch: work/42",
    "basic interpolation failed, got: " .. result)
  print("✓ interpolate_prompt handles basic substitution")
end
test_interpolate_basic()

-- Test interpolation with % in values (this is the gsub bug)
local function test_interpolate_percent()
  local template = "Title: {title}\nBody: {body}"
  local result = prompt.interpolate_prompt(template, {
    title = "fix 100% of bugs",
    body = "increase coverage from %50 to %100",
  })
  assert(result == "Title: fix 100% of bugs\nBody: increase coverage from %50 to %100",
    "percent interpolation failed, got: " .. result)
  print("✓ interpolate_prompt handles % in values")
end
test_interpolate_percent()

-- Test interpolation with %1 capture reference in values (would crash old gsub)
local function test_interpolate_percent_digit()
  local template = "{title}: {body}"
  local result = prompt.interpolate_prompt(template, {
    title = "test %1 %2 refs",
    body = "body with %0 and %9",
  })
  assert(result == "test %1 %2 refs: body with %0 and %9",
    "percent-digit interpolation failed, got: " .. result)
  print("✓ interpolate_prompt handles %N capture references in values")
end
test_interpolate_percent_digit()

-- Test interpolation with missing placeholder (no change)
local function test_interpolate_missing_key()
  local template = "{title} and {missing}"
  local result = prompt.interpolate_prompt(template, {
    title = "hello",
  })
  assert(result == "hello and {missing}",
    "missing key should leave placeholder, got: " .. result)
  print("✓ interpolate_prompt leaves unknown placeholders unchanged")
end
test_interpolate_missing_key()

-- Test interpolation with empty value
local function test_interpolate_empty_value()
  local template = "Title: {title}\nBody: {body}"
  local result = prompt.interpolate_prompt(template, {
    title = "something",
    body = "",
  })
  assert(result == "Title: something\nBody: ",
    "empty value interpolation failed, got: " .. result)
  print("✓ interpolate_prompt handles empty values")
end
test_interpolate_empty_value()

-- Test interpolation with value containing braces
local function test_interpolate_braces_in_value()
  local template = "{title}: {body}"
  local result = prompt.interpolate_prompt(template, {
    title = "fix {thing}",
    body = "body text",
  })
  assert(result == "fix {thing}: body text",
    "braces in value failed, got: " .. result)
  print("✓ interpolate_prompt handles braces in values")
end
test_interpolate_braces_in_value()

-- Sanity: interpolate_prompt handles % safely
local function test_interpolate_prompt_safe()
  local template = "{title}: {body}"
  local result = prompt.interpolate_prompt(template, {
    title = "100% coverage",
    body = "fix %1 and %2 refs",
  })
  assert(result == "100% coverage: fix %1 and %2 refs",
    "interpolate_prompt should handle % safely, got: " .. result)
  print("✓ interpolate_prompt handles % safely (reference)")
end
test_interpolate_prompt_safe()

-- Test plan_diagnostic when no files exist
local function test_diagnostic_no_files()
  local msg = prompt.plan_diagnostic("/nonexistent/path/that/does/not/exist")
  assert(msg:find("plan.md not found") or msg:find("not found"),
    "diagnostic should mention plan.md not found, got: " .. msg)
  print("✓ plan_diagnostic reports when no files found")
end
test_diagnostic_no_files()

-- Test plan_diagnostic with update.md (bail condition)
local function test_diagnostic_with_update()
  local tmpdir = os.getenv("TEST_TMPDIR")
  if not tmpdir then
    print("✓ plan_diagnostic bail test skipped (no TEST_TMPDIR)")
    return
  end

  local plan_dir = tmpdir .. "/plan"
  os.execute("mkdir -p " .. plan_dir)

  -- Write update.md (bail condition)
  local f = io.open(plan_dir .. "/update.md", "w")
  f:write("Could not identify entry point for this issue.\n")
  f:close()

  local msg = prompt.plan_diagnostic(plan_dir)
  assert(msg:find("update.md"), "diagnostic should mention update.md, got: " .. msg)
  assert(msg:find("Could not identify"), "diagnostic should include update.md content, got: " .. msg)
  print("✓ plan_diagnostic reports bail condition from update.md")
end
test_diagnostic_with_update()

-- Test build_do_prompt handles % in plan contents
local function test_do_prompt_percent_in_plan()
  local template = "Title: {title}\nPlan:\n{plan.md contents}\nBranch: {branch}"
  local plan = "increase test coverage to 100%"
  local ok, result = pcall(prompt.build_do_prompt, template, "fix tests", plan, "work/42")
  assert(ok, "build_do_prompt should not crash with % in plan, got error: " .. tostring(result))
  assert(result == "Title: fix tests\nPlan:\nincrease test coverage to 100%\nBranch: work/42",
    "wrong result: " .. tostring(result))
  print("✓ build_do_prompt handles % in plan contents")
end
test_do_prompt_percent_in_plan()

-- Test build_do_prompt handles %1 capture ref in title
local function test_do_prompt_capture_ref_in_title()
  local template = "Title: {title}\nPlan:\n{plan.md contents}\nBranch: {branch}"
  local ok, result = pcall(prompt.build_do_prompt, template, "fix %1 regex", "plan text", "work/42")
  assert(ok, "build_do_prompt should not crash with %1 in title, got error: " .. tostring(result))
  assert(result == "Title: fix %1 regex\nPlan:\nplan text\nBranch: work/42",
    "wrong result: " .. tostring(result))
  print("✓ build_do_prompt handles %N capture references in title")
end
test_do_prompt_capture_ref_in_title()

-- Test build_check_prompt handles % in do contents
local function test_check_prompt_percent_in_do()
  local template = "Plan:\n{plan.md contents}\nDo:\n{do.md contents}"
  local do_contents = "coverage went from 50% to 100%"
  local ok, result = pcall(prompt.build_check_prompt, template, "the plan", do_contents)
  assert(ok, "build_check_prompt should not crash with % in do contents, got error: " .. tostring(result))
  assert(result == "Plan:\nthe plan\nDo:\ncoverage went from 50% to 100%",
    "wrong result: " .. tostring(result))
  print("✓ build_check_prompt handles % in do contents")
end
test_check_prompt_percent_in_do()

-- Test build_fix_prompt interpolates all variables
local function test_build_fix_prompt_basic()
  local template = "Title: {title}\nPlan:\n{plan.md contents}\nFeedback:\n{check.md contents}\nBranch: {branch}"
  local result = prompt.build_fix_prompt(template, "fix docs", "the plan", "model name is wrong", "work/79")
  assert(result == "Title: fix docs\nPlan:\nthe plan\nFeedback:\nmodel name is wrong\nBranch: work/79",
    "should interpolate all vars, got: " .. tostring(result))
  print("✓ build_fix_prompt interpolates all variables")
end
test_build_fix_prompt_basic()

-- Test build_fix_prompt handles % in check feedback
local function test_build_fix_prompt_percent()
  local template = "Plan:\n{plan.md contents}\nFeedback:\n{check.md contents}"
  local check = "coverage dropped from 100% to 50%"
  local ok, result = pcall(prompt.build_fix_prompt, template, "t", "p", check, "work/1")
  assert(ok, "should not crash with % in check feedback, got: " .. tostring(result))
  print("✓ build_fix_prompt handles % in check feedback")
end
test_build_fix_prompt_percent()

-- Test build_friction_prompt interpolates friction_path
local function test_build_friction_prompt_basic()
  local template = "reflect on friction.\n\nWrite `{friction_path}`:\n\n    ## Friction\n    <items>"
  local result = prompt.build_friction_prompt(template, "o/work/plan/friction.md")
  assert(result == "reflect on friction.\n\nWrite `o/work/plan/friction.md`:\n\n    ## Friction\n    <items>",
    "should interpolate friction_path, got: " .. tostring(result))
  print("✓ build_friction_prompt interpolates friction_path")
end
test_build_friction_prompt_basic()

-- Test build_friction_prompt handles different phase paths
local function test_build_friction_prompt_phases()
  local template = "Write `{friction_path}`"
  for _, path in ipairs({"o/work/plan/friction.md", "o/work/do/friction.md", "o/work/check/friction.md"}) do
    local result = prompt.build_friction_prompt(template, path)
    assert(result == "Write `" .. path .. "`",
      "should interpolate " .. path .. ", got: " .. tostring(result))
  end
  print("✓ build_friction_prompt works for all phase paths")
end
test_build_friction_prompt_phases()

-- Test build_friction_prompt works for fix phase path
local function test_build_friction_prompt_fix_phase()
  local template = "Write `{friction_path}`"
  local result = prompt.build_friction_prompt(template, "o/work/fix/friction.md")
  assert(result == "Write `o/work/fix/friction.md`",
    "should interpolate o/work/fix/friction.md, got: " .. tostring(result))
  print("✓ build_friction_prompt works for fix phase path")
end
test_build_friction_prompt_fix_phase()

-- Test fix.md prompt writes artifacts to o/work/fix/, not o/work/do/
local function test_fix_prompt_uses_fix_directory()
  local f = io.open("sys/work/fix.md", "r")
  assert(f, "should be able to read sys/work/fix.md")
  local content = f:read("*a")
  f:close()
  -- fix prompt must write to o/work/fix/ so it doesn't overwrite do phase artifacts
  assert(content:find("o/work/fix/do.md", 1, true),
    "fix prompt should write to o/work/fix/do.md")
  assert(content:find("o/work/fix/update.md", 1, true),
    "fix prompt should write to o/work/fix/update.md")
  -- must not reference o/work/do/ for output paths
  assert(not content:find("o/work/do/do.md", 1, true),
    "fix prompt must not write to o/work/do/do.md (would overwrite do phase artifacts)")
  assert(not content:find("o/work/do/update.md", 1, true),
    "fix prompt must not write to o/work/do/update.md (would overwrite do phase artifacts)")
  print("✓ fix.md prompt writes to o/work/fix/ directory")
end
test_fix_prompt_uses_fix_directory()

print("\nAll work-prompt tests passed!")
