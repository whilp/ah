#!/usr/bin/env cosmic
-- test_issue.tl: tests for ah.work.issue module (selection, labels)

local record Label
  name: string
end

local record Issue
  number: integer
  title: string
  body: string
  url: string
  labels: {Label}
  createdAt: string
  extra: string
end

local record SelectedIssue
  number: integer
  title: string
  body: string
  url: string
end

local record WorkIssue
  get_priority: function({Label}): integer
  sort_issues: function({Issue})
  select_issue: function({Issue}): SelectedIssue
  required_labels: {string}
  ensure_labels: function(string): boolean, string
end

local issue = require("ah.work.issue") as WorkIssue

-- Test get_priority
local function test_get_priority()
  assert(issue.get_priority({}) == 3, "no labels should return 3")
  assert(issue.get_priority({{name = "bug"}}) == 3, "non-priority label should return 3")
  assert(issue.get_priority({{name = "p0"}}) == 0, "p0 should return 0")
  assert(issue.get_priority({{name = "p1"}}) == 1, "p1 should return 1")
  assert(issue.get_priority({{name = "p2"}}) == 2, "p2 should return 2")
  assert(issue.get_priority({{name = "p0"}, {name = "bug"}}) == 0, "p0 with other labels should return 0")
  print("✓ get_priority works correctly")
end
test_get_priority()

-- Test sort_issues by priority
local function test_priority_sorting()
  local issues = {
    {number = 1, labels = {}, createdAt = "2024-01-01T00:00:00Z"},
    {number = 2, labels = {{name = "p2"}}, createdAt = "2024-01-02T00:00:00Z"},
    {number = 3, labels = {{name = "p0"}}, createdAt = "2024-01-03T00:00:00Z"},
    {number = 4, labels = {{name = "p1"}}, createdAt = "2024-01-04T00:00:00Z"}
  }

  issue.sort_issues(issues)
  assert(issues[1].number == 3, "p0 issue should be first")
  assert(issues[2].number == 4, "p1 issue should be second")
  assert(issues[3].number == 2, "p2 issue should be third")
  assert(issues[4].number == 1, "unlabeled issue should be last")
  print("✓ sort_issues orders by priority")
end
test_priority_sorting()

-- Test sort_issues by date within same priority
local function test_date_sorting()
  local issues = {
    {number = 1, labels = {{name = "p1"}}, createdAt = "2024-01-05T00:00:00Z"},
    {number = 2, labels = {{name = "p1"}}, createdAt = "2024-01-01T00:00:00Z"},
    {number = 3, labels = {{name = "p1"}}, createdAt = "2024-01-03T00:00:00Z"}
  }

  issue.sort_issues(issues)
  assert(issues[1].number == 2, "oldest issue should be first")
  assert(issues[2].number == 3, "middle issue should be second")
  assert(issues[3].number == 1, "newest issue should be last")
  print("✓ sort_issues orders by date within priority")
end
test_date_sorting()

-- Test select_issue returns correct format
local function test_select_issue()
  local issues = {
    {number = 42, title = "Test", body = "Body", url = "url1", labels = {{name = "p1"}}, createdAt = "2024-01-01T00:00:00Z", extra = "field"},
    {number = 43, title = "Higher", body = "Body2", url = "url2", labels = {{name = "p0"}}, createdAt = "2024-01-02T00:00:00Z"}
  }

  local selected = issue.select_issue(issues)
  assert(selected.number == 43, "should select p0 issue")
  assert(selected.title == "Higher", "should include title")
  assert(selected.body == "Body2", "should include body")
  assert(selected.url == "url2", "should include url")
  local raw = selected as {string:any}
  assert(raw.extra == nil, "should not include extra fields")
  assert(raw.labels == nil, "should not include labels")
  assert(raw.createdAt == nil, "should not include createdAt")
  print("✓ select_issue returns correct format")
end
test_select_issue()

-- Test select_issue with empty list
local function test_empty_issues()
  local selected = issue.select_issue({})
  assert(selected == nil, "should return nil for empty list")
  print("✓ select_issue handles empty list")
end
test_empty_issues()

-- Test that required_labels exists and contains expected labels
local function test_required_labels()
  assert(issue.required_labels ~= nil, "required_labels should be exported")
  local expected = {"todo", "doing", "done", "failed", "friction"}
  local found: {string:boolean} = {}
  for _, label in ipairs(issue.required_labels) do
    found[label] = true
  end

  for _, label in ipairs(expected) do
    assert(found[label], "required_labels should contain '" .. label .. "'")
  end

  assert(#issue.required_labels == #expected,
    "required_labels should have exactly " .. #expected .. " labels, got " .. #issue.required_labels)
  print("✓ required_labels contains all expected labels")
end
test_required_labels()

-- Test that ensure_labels is exported as a function
local function test_ensure_labels_exported()
  assert(type(issue.ensure_labels) == "function", "ensure_labels should be exported as a function")
  print("✓ ensure_labels is exported")
end
test_ensure_labels_exported()

print("\nAll work-issue tests passed!")
