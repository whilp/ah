#!/usr/bin/env cosmic
-- test_work_fix.tl: tests for check-to-do retry loop helpers
--
-- The work flow is linear: plan -> do -> push -> check -> act.
-- When check returns "needs-fixes", the work is wasted — no PR, issue
-- labeled failed. These tests cover helpers for a retry loop:
-- check feedback is fed back into a fix prompt, do/push/check re-run.

local record ParsedActions
  verdict: string
  actions: {any}
  success: boolean
end

local record Work
  build_fix_prompt: function(string, string, string, string, string): string
  parse_actions: function(string): ParsedActions, string
  interpolate_prompt: function(string, {string:string}): string
end

local work = require("ah.work") as Work

-- Test: build_fix_prompt interpolates all variables
local function test_build_fix_prompt_basic()
  local template = "Title: {title}\nPlan:\n{plan.md contents}\nFeedback:\n{check.md contents}\nBranch: {branch}"
  local result = work.build_fix_prompt(template, "fix docs", "the plan", "model name is wrong", "work/79")
  assert(result == "Title: fix docs\nPlan:\nthe plan\nFeedback:\nmodel name is wrong\nBranch: work/79",
    "should interpolate all vars, got: " .. tostring(result))
  print("ok build_fix_prompt interpolates all variables")
end
test_build_fix_prompt_basic()

-- Test: build_fix_prompt handles % in check feedback
local function test_build_fix_prompt_percent()
  local template = "Plan:\n{plan.md contents}\nFeedback:\n{check.md contents}"
  local check = "coverage dropped from 100% to 50%"
  local ok, result = pcall(work.build_fix_prompt, template, "t", "p", check, "work/1")
  assert(ok, "should not crash with % in check feedback, got: " .. tostring(result))
  print("ok build_fix_prompt handles % in check feedback")
end
test_build_fix_prompt_percent()

-- Test: parse_actions returns needs-fixes verdict correctly
local function test_parse_needs_fixes()
  local content = '{"verdict": "needs-fixes", "actions": [{"action": "comment_issue", "body": "fix the model name"}]}'
  local result = work.parse_actions(content)
  assert(result ~= nil, "should parse valid json")
  assert(result.verdict == "needs-fixes", "verdict should be needs-fixes, got: " .. result.verdict)
  assert(result.success == false, "success should be false for needs-fixes")
  assert(#result.actions == 1, "should have one action")
  print("ok parse_actions handles needs-fixes verdict")
end
test_parse_needs_fixes()

print("\nAll work-fix tests passed!")
