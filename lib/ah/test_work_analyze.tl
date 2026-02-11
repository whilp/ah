#!/usr/bin/env cosmic
-- test_work_analyze.tl: tests for friction analysis parsing, validation, and CLI

local record FrictionIssue
  title: string
  body: string
  labels: {string}
end

local record FrictionIssues
  issues: {FrictionIssue}
end

local record Work
  main: function({string}): integer
  parse_friction_issues: function(string): FrictionIssues, string
  validate_friction_issue: function(FrictionIssue): boolean, string
end

local work = require("ah.work") as Work

-- parse_friction_issues: valid input with issues
local function test_parse_valid()
  local content = '{"issues": [{"title": "friction: slow builds", "body": "## Problem\\nBuilds took 5 min", "labels": ["friction"]}]}'
  local result, err = work.parse_friction_issues(content)
  assert(result ~= nil, "should parse valid json, err: " .. tostring(err))
  assert(#result.issues == 1, "should have 1 issue, got: " .. #result.issues)
  assert(result.issues[1].title == "friction: slow builds", "wrong title: " .. result.issues[1].title)
  assert(result.issues[1].labels[1] == "friction", "wrong label: " .. tostring(result.issues[1].labels[1]))
  print("✓ parse_friction_issues handles valid input")
end
test_parse_valid()

-- parse_friction_issues: empty issues array
local function test_parse_empty()
  local content = '{"issues": []}'
  local result = work.parse_friction_issues(content)
  assert(result ~= nil, "should parse valid json")
  assert(#result.issues == 0, "should have 0 issues")
  print("✓ parse_friction_issues handles empty issues array")
end
test_parse_empty()

-- parse_friction_issues: nil content
local function test_parse_nil()
  local result, err = work.parse_friction_issues(nil)
  assert(result == nil, "should return nil for nil input")
  assert(err == "no content", "should return error: " .. tostring(err))
  print("✓ parse_friction_issues handles nil content")
end
test_parse_nil()

-- parse_friction_issues: invalid json
local function test_parse_invalid()
  local result, err = work.parse_friction_issues("not json")
  assert(result == nil, "should return nil for invalid json")
  assert(err == "invalid json", "should return error: " .. tostring(err))
  print("✓ parse_friction_issues handles invalid json")
end
test_parse_invalid()

-- parse_friction_issues: missing issues key defaults to empty
local function test_parse_missing_issues()
  local content = '{"something": "else"}'
  local result = work.parse_friction_issues(content)
  assert(result ~= nil, "should parse valid json")
  assert(#result.issues == 0, "should default to empty issues")
  print("✓ parse_friction_issues defaults missing issues to empty")
end
test_parse_missing_issues()

-- parse_friction_issues: multiple issues
local function test_parse_multiple()
  local content = '{"issues": [{"title": "friction: a", "body": "b", "labels": ["friction"]}, {"title": "friction: c", "body": "d", "labels": ["friction", "p1"]}]}'
  local result = work.parse_friction_issues(content)
  assert(result ~= nil, "should parse valid json")
  assert(#result.issues == 2, "should have 2 issues, got: " .. #result.issues)
  assert(result.issues[2].title == "friction: c", "wrong second title")
  assert(#result.issues[2].labels == 2, "second issue should have 2 labels")
  print("✓ parse_friction_issues handles multiple issues")
end
test_parse_multiple()

-- parse_friction_issues: missing fields default to empty
local function test_parse_missing_fields()
  local content = '{"issues": [{}]}'
  local result = work.parse_friction_issues(content)
  assert(result ~= nil, "should parse valid json")
  assert(#result.issues == 1, "should have 1 issue")
  assert(result.issues[1].title == "", "title should default to empty")
  assert(result.issues[1].body == "", "body should default to empty")
  assert(#result.issues[1].labels == 0, "labels should default to empty")
  print("✓ parse_friction_issues defaults missing fields")
end
test_parse_missing_fields()

-- validate_friction_issue: valid issue
local function test_validate_valid()
  local issue: FrictionIssue = {title = "friction: slow builds", body = "details here", labels = {"friction"}}
  local ok, err = work.validate_friction_issue(issue)
  assert(ok == true, "should accept valid issue, err: " .. tostring(err))
  print("✓ validate_friction_issue accepts valid issue")
end
test_validate_valid()

-- validate_friction_issue: missing title
local function test_validate_no_title()
  local issue: FrictionIssue = {title = "", body = "details", labels = {"friction"}}
  local ok, err = work.validate_friction_issue(issue)
  assert(ok == false, "should reject missing title")
  assert(err == "missing title", "wrong error: " .. tostring(err))
  print("✓ validate_friction_issue rejects missing title")
end
test_validate_no_title()

-- validate_friction_issue: missing body
local function test_validate_no_body()
  local issue: FrictionIssue = {title = "friction: something", body = "", labels = {"friction"}}
  local ok, err = work.validate_friction_issue(issue)
  assert(ok == false, "should reject missing body")
  assert(err == "missing body", "wrong error: " .. tostring(err))
  print("✓ validate_friction_issue rejects missing body")
end
test_validate_no_body()

-- validate_friction_issue: wrong title prefix
local function test_validate_bad_prefix()
  local issue: FrictionIssue = {title = "bug: something broke", body = "details", labels = {"friction"}}
  local ok, err = work.validate_friction_issue(issue)
  assert(ok == false, "should reject wrong prefix")
  assert(err == "title must start with 'friction: '", "wrong error: " .. tostring(err))
  print("✓ validate_friction_issue rejects wrong title prefix")
end
test_validate_bad_prefix()

-- CLI: analyze --help returns 0
local function test_analyze_help()
  local rc = work.main({"--no-sandbox", "analyze", "--help"})
  assert(rc == 0, "analyze --help should return 0, got: " .. tostring(rc))
  print("✓ analyze --help returns 0")
end
test_analyze_help()

-- CLI: analyze without --repo returns 1
local function test_analyze_no_repo()
  local rc = work.main({"--no-sandbox", "analyze"})
  assert(rc == 1, "analyze without --repo should return 1, got: " .. tostring(rc))
  print("✓ analyze without --repo returns 1")
end
test_analyze_no_repo()

print("\nAll work-analyze tests passed!")
