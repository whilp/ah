#!/usr/bin/env cosmic
-- test_action.tl: tests for ah.work.action module

local record ParsedActions
  verdict: string
  actions: {any}
  success: boolean
end

local record WorkAction
  parse_actions: function(string): ParsedActions, string
  validate_branch: function(string): boolean, string
  execute_action: function(string, {string:any}, function(string)): boolean
  issue_number_from_url: function(string): string
  build_pr_body: function(string, string): string
end

local action = require("ah.work.action") as WorkAction

-- Test parse_actions with passing verdict
local function test_parse_pass()
  local content = '{"verdict": "pass", "actions": [{"action": "create_pr"}]}'
  local result = action.parse_actions(content)
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
  local result = action.parse_actions(content)
  assert(result ~= nil, "should parse valid json")
  assert(result.verdict == "fail", "verdict should be fail")
  assert(result.success == false, "success should be false for fail")
  print("✓ parse_actions handles failing verdict")
end
test_parse_fail()

-- Test parse_actions with missing verdict
local function test_parse_missing_verdict()
  local content = '{"actions": []}'
  local result = action.parse_actions(content)
  assert(result ~= nil, "should parse valid json")
  assert(result.verdict == "unknown", "verdict should default to unknown")
  assert(result.success == false, "success should be false for unknown")
  print("✓ parse_actions defaults missing verdict to unknown")
end
test_parse_missing_verdict()

-- Test parse_actions with nil content
local function test_parse_nil()
  local result, err = action.parse_actions(nil)
  assert(result == nil, "should return nil for nil input")
  assert(err == "no content", "should return error message")
  print("✓ parse_actions handles nil content")
end
test_parse_nil()

-- Test parse_actions with invalid json
local function test_parse_invalid()
  local result, err = action.parse_actions("not valid json")
  assert(result == nil, "should return nil for invalid json")
  assert(err == "invalid json", "should return error message")
  print("✓ parse_actions handles invalid json")
end
test_parse_invalid()

-- Test parse_actions with empty actions
local function test_parse_empty_actions()
  local content = '{"verdict": "pass"}'
  local result = action.parse_actions(content)
  assert(result ~= nil, "should parse valid json")
  assert(#result.actions == 0, "actions should default to empty")
  print("✓ parse_actions defaults missing actions to empty")
end
test_parse_empty_actions()

-- Test parse_actions returns needs-fixes verdict correctly
local function test_parse_needs_fixes()
  local content = '{"verdict": "needs-fixes", "actions": [{"action": "comment_issue", "body": "fix the model name"}]}'
  local result = action.parse_actions(content)
  assert(result ~= nil, "should parse valid json")
  assert(result.verdict == "needs-fixes", "verdict should be needs-fixes, got: " .. result.verdict)
  assert(result.success == false, "success should be false for needs-fixes")
  assert(#result.actions == 1, "should have one action")
  print("✓ parse_actions handles needs-fixes verdict")
end
test_parse_needs_fixes()

-- Test validate_branch with valid branch
local function test_validate_branch_valid()
  local ok, err = action.validate_branch("work/123-fix-bug")
  assert(ok == true, "should accept work/ prefix")
  assert(err == nil, "should not have error")
  print("✓ validate_branch accepts work/ prefix")
end
test_validate_branch_valid()

-- Test validate_branch with invalid branch
local function test_validate_branch_invalid()
  local ok, err = action.validate_branch("main")
  assert(ok == false, "should reject non-work branch")
  assert(err == "branch must start with work/", "should return error")
  print("✓ validate_branch rejects non-work/ prefix")
end
test_validate_branch_invalid()

-- Test validate_branch with feature branch
local function test_validate_branch_feature()
  local ok, err = action.validate_branch("feature/new-thing")
  assert(ok == false, "should reject feature/ prefix")
  assert(err == "branch must start with work/", "should return error")
  print("✓ validate_branch rejects feature/ prefix")
end
test_validate_branch_feature()

-- Test validate_branch with nil
local function test_validate_branch_nil()
  local ok, err = action.validate_branch(nil)
  assert(ok == false, "should reject nil branch")
  assert(err == "missing branch", "should return missing error")
  print("✓ validate_branch rejects nil branch")
end
test_validate_branch_nil()

-- Test execute_action with unknown action type
local function test_execute_action_unknown()
  local logs: {string} = {}
  local log_fn = function(msg: string) table.insert(logs, msg) end
  local a: {string:any} = {action = "unknown_action"}
  local ok = action.execute_action("https://example.com", a, log_fn)
  assert(ok == true, "unknown action should succeed (skip)")
  assert(#logs == 2, "should have 2 log entries")
  assert(logs[1] == "Executing: unknown_action", "should log action type")
  assert(logs[2] == "  Skipped: unknown action type", "should log skip")
  print("✓ execute_action skips unknown action types")
end
test_execute_action_unknown()

-- Test issue_number_from_url extracts number
local function test_issue_number_from_url()
  local num = action.issue_number_from_url("https://api.github.com/repos/owner/repo/issues/42")
  assert(num == "42", "should extract issue number, got: " .. tostring(num))
  print("✓ issue_number_from_url extracts number from GitHub API URL")
end
test_issue_number_from_url()

-- Test issue_number_from_url with html url
local function test_issue_number_from_html_url()
  local num = action.issue_number_from_url("https://github.com/owner/repo/issues/7")
  assert(num == "7", "should extract issue number from html url, got: " .. tostring(num))
  print("✓ issue_number_from_url extracts number from HTML URL")
end
test_issue_number_from_html_url()

-- Test issue_number_from_url with nil
local function test_issue_number_from_url_nil()
  local num = action.issue_number_from_url(nil)
  assert(num == nil, "should return nil for nil input")
  print("✓ issue_number_from_url returns nil for nil")
end
test_issue_number_from_url_nil()

-- Test issue_number_from_url with no match
local function test_issue_number_from_url_no_match()
  local num = action.issue_number_from_url("https://example.com/foo")
  assert(num == nil, "should return nil for non-matching url")
  print("✓ issue_number_from_url returns nil for non-matching URL")
end
test_issue_number_from_url_no_match()

-- Test build_pr_body appends issue ref
local function test_build_pr_body_appends()
  local body = action.build_pr_body("Some description", "https://api.github.com/repos/o/r/issues/42")
  assert(body == "Some description\n\nCloses #42", "should append ref, got: " .. body)
  print("✓ build_pr_body appends Closes #N")
end
test_build_pr_body_appends()

-- Test build_pr_body does not duplicate existing ref
local function test_build_pr_body_no_duplicate()
  local body = action.build_pr_body("Fix bug\n\nCloses #42", "https://api.github.com/repos/o/r/issues/42")
  assert(body == "Fix bug\n\nCloses #42", "should not duplicate ref, got: " .. body)
  print("✓ build_pr_body skips when ref already present")
end
test_build_pr_body_no_duplicate()

-- Test build_pr_body with nil body
local function test_build_pr_body_nil()
  local body = action.build_pr_body(nil, "https://api.github.com/repos/o/r/issues/5")
  assert(body == "\n\nCloses #5", "should handle nil body, got: " .. body)
  print("✓ build_pr_body handles nil body")
end
test_build_pr_body_nil()

-- Test build_pr_body with no issue in url
local function test_build_pr_body_no_issue()
  local body = action.build_pr_body("Some text", "https://example.com/foo")
  assert(body == "Some text", "should not modify body without issue, got: " .. body)
  print("✓ build_pr_body leaves body unchanged when no issue number")
end
test_build_pr_body_no_issue()

print("\nAll work-action tests passed!")
