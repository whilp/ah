#!/usr/bin/env cosmic
-- test_work_act.tl: tests for work act phase logic

local record ParsedActions
  verdict: string
  actions: {any}
  success: boolean
end

local record Work
  parse_actions: function(string): ParsedActions, string
  validate_branch: function(string): boolean, string
  execute_action: function(string, {string:any}, function(string)): boolean
end

local work = require("ah.work") as Work

-- Test parse_actions with passing verdict
local function test_parse_pass()
  local content = '{"verdict": "pass", "actions": [{"action": "create_pr"}]}'
  local result = work.parse_actions(content)
  assert(result ~= nil, "should parse valid json")
  assert(result.verdict == "pass", "verdict should be pass")
  assert(result.success == true, "success should be true for pass")
  assert(#result.actions == 1, "should have one action")
  print("✓ parse_actions handles passing verdict")
end
test_parse_pass()

-- Test parse_actions with failing verdict
local function test_parse_fail()
  local content = '{"verdict": "fail", "actions": []}'
  local result = work.parse_actions(content)
  assert(result ~= nil, "should parse valid json")
  assert(result.verdict == "fail", "verdict should be fail")
  assert(result.success == false, "success should be false for fail")
  print("✓ parse_actions handles failing verdict")
end
test_parse_fail()

-- Test parse_actions with missing verdict
local function test_parse_missing_verdict()
  local content = '{"actions": []}'
  local result = work.parse_actions(content)
  assert(result ~= nil, "should parse valid json")
  assert(result.verdict == "unknown", "verdict should default to unknown")
  assert(result.success == false, "success should be false for unknown")
  print("✓ parse_actions defaults missing verdict to unknown")
end
test_parse_missing_verdict()

-- Test parse_actions with nil content
local function test_parse_nil()
  local result, err = work.parse_actions(nil)
  assert(result == nil, "should return nil for nil input")
  assert(err == "no content", "should return error message")
  print("✓ parse_actions handles nil content")
end
test_parse_nil()

-- Test parse_actions with invalid json
local function test_parse_invalid()
  local result, err = work.parse_actions("not valid json")
  assert(result == nil, "should return nil for invalid json")
  assert(err == "invalid json", "should return error message")
  print("✓ parse_actions handles invalid json")
end
test_parse_invalid()

-- Test parse_actions with empty actions
local function test_parse_empty_actions()
  local content = '{"verdict": "pass"}'
  local result = work.parse_actions(content)
  assert(result ~= nil, "should parse valid json")
  assert(#result.actions == 0, "actions should default to empty")
  print("✓ parse_actions defaults missing actions to empty")
end
test_parse_empty_actions()

-- Test validate_branch with valid branch
local function test_validate_branch_valid()
  local ok, err = work.validate_branch("work/123-fix-bug")
  assert(ok == true, "should accept work/ prefix")
  assert(err == nil, "should not have error")
  print("✓ validate_branch accepts work/ prefix")
end
test_validate_branch_valid()

-- Test validate_branch with invalid branch
local function test_validate_branch_invalid()
  local ok, err = work.validate_branch("main")
  assert(ok == false, "should reject non-work branch")
  assert(err == "branch must start with work/", "should return error")
  print("✓ validate_branch rejects non-work/ prefix")
end
test_validate_branch_invalid()

-- Test validate_branch with feature branch
local function test_validate_branch_feature()
  local ok, err = work.validate_branch("feature/new-thing")
  assert(ok == false, "should reject feature/ prefix")
  assert(err == "branch must start with work/", "should return error")
  print("✓ validate_branch rejects feature/ prefix")
end
test_validate_branch_feature()

-- Test validate_branch with nil
local function test_validate_branch_nil()
  local ok, err = work.validate_branch(nil)
  assert(ok == false, "should reject nil branch")
  assert(err == "missing branch", "should return missing error")
  print("✓ validate_branch rejects nil branch")
end
test_validate_branch_nil()

-- Test execute_action with unknown action type
local function test_execute_action_unknown()
  local logs: {string} = {}
  local log_fn = function(msg: string) table.insert(logs, msg) end
  local action: {string:any} = {action = "unknown_action"}
  local ok = work.execute_action("https://example.com", action, log_fn)
  assert(ok == true, "unknown action should succeed (skip)")
  assert(#logs == 2, "should have 2 log entries")
  assert(logs[1] == "Executing: unknown_action", "should log action type")
  assert(logs[2] == "  Skipped: unknown action type", "should log skip")
  print("✓ execute_action skips unknown action types")
end
test_execute_action_unknown()

print("\nAll work-act tests passed!")
