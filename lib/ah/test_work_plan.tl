#!/usr/bin/env cosmic
-- test_work_plan.tl: tests for plan phase prompt interpolation and diagnostics

local record Work
  interpolate_prompt: function(string, {string:string}): string
  plan_diagnostic: function(string): string
end

local work = require("ah.work") as Work

-- Test basic interpolation
local function test_interpolate_basic()
  local template = "Plan for {title}\n\n{body}\n\nBranch: work/{issue_number}"
  local result = work.interpolate_prompt(template, {
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
  local result = work.interpolate_prompt(template, {
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
  local result = work.interpolate_prompt(template, {
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
  local result = work.interpolate_prompt(template, {
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
  local result = work.interpolate_prompt(template, {
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
  local result = work.interpolate_prompt(template, {
    title = "fix {thing}",
    body = "body text",
  })
  assert(result == "fix {thing}: body text",
    "braces in value failed, got: " .. result)
  print("✓ interpolate_prompt handles braces in values")
end
test_interpolate_braces_in_value()

-- Test plan_diagnostic when no files exist
local function test_diagnostic_no_files()
  local msg = work.plan_diagnostic("/nonexistent/path/that/does/not/exist")
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

  local msg = work.plan_diagnostic(plan_dir)
  assert(msg:find("update.md"), "diagnostic should mention update.md, got: " .. msg)
  assert(msg:find("Could not identify"), "diagnostic should include update.md content, got: " .. msg)
  print("✓ plan_diagnostic reports bail condition from update.md")
end
test_diagnostic_with_update()

print("\nAll work-plan tests passed!")
