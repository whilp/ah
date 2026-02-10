#!/usr/bin/env cosmic
-- test_work_act.tl: tests for work-act script

local path = require("cosmo.path")

local record ParsedActions
  verdict: string
  actions: {any}
  success: boolean
end

local record WorkAct
  parse_actions: function(string): ParsedActions, string
end

local script_path = path.join(os.getenv("TEST_BIN") or "bin", "..", "bin", "work-act")
local wa = dofile(script_path) as WorkAct

-- Test parse_actions with passing verdict
local function test_parse_pass()
  local content = '{"verdict": "pass", "actions": [{"action": "create_pr"}]}'
  local result = wa.parse_actions(content)
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
  local result = wa.parse_actions(content)
  assert(result ~= nil, "should parse valid json")
  assert(result.verdict == "fail", "verdict should be fail")
  assert(result.success == false, "success should be false for fail")
  print("✓ parse_actions handles failing verdict")
end
test_parse_fail()

-- Test parse_actions with missing verdict
local function test_parse_missing_verdict()
  local content = '{"actions": []}'
  local result = wa.parse_actions(content)
  assert(result ~= nil, "should parse valid json")
  assert(result.verdict == "unknown", "verdict should default to unknown")
  assert(result.success == false, "success should be false for unknown")
  print("✓ parse_actions defaults missing verdict to unknown")
end
test_parse_missing_verdict()

-- Test parse_actions with nil content
local function test_parse_nil()
  local result, err = wa.parse_actions(nil)
  assert(result == nil, "should return nil for nil input")
  assert(err == "no content", "should return error message")
  print("✓ parse_actions handles nil content")
end
test_parse_nil()

-- Test parse_actions with invalid json
local function test_parse_invalid()
  local result, err = wa.parse_actions("not valid json")
  assert(result == nil, "should return nil for invalid json")
  assert(err == "invalid json", "should return error message")
  print("✓ parse_actions handles invalid json")
end
test_parse_invalid()

-- Test parse_actions with empty actions
local function test_parse_empty_actions()
  local content = '{"verdict": "pass"}'
  local result = wa.parse_actions(content)
  assert(result ~= nil, "should parse valid json")
  assert(#result.actions == 0, "actions should default to empty")
  print("✓ parse_actions defaults missing actions to empty")
end
test_parse_empty_actions()

print("\nAll work-act tests passed!")
