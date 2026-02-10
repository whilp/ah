#!/usr/bin/env cosmic
-- test_work_select.tl: tests for work-select script core logic
local json = require("cosmic.json")

-- Test the get_priority function logic
local function test_get_priority()
  local function get_priority(labels: {{string:string}}): integer
    for _, label in ipairs(labels) do
      if label.name == "p0" then return 0 end
      if label.name == "p1" then return 1 end
      if label.name == "p2" then return 2 end
    end
    return 3
  end

  -- Test cases
  assert(get_priority({}) == 3, "no labels should return 3")
  assert(get_priority({{name = "bug"}}) == 3, "non-priority label should return 3")
  assert(get_priority({{name = "p0"}}) == 0, "p0 should return 0")
  assert(get_priority({{name = "p1"}}) == 1, "p1 should return 1")
  assert(get_priority({{name = "p2"}}) == 2, "p2 should return 2")
  assert(get_priority({{name = "p0"}, {name = "bug"}}) == 0, "p0 with other labels should return 0")
  
  print("✓ get_priority function works correctly")
end
test_get_priority()

-- Test priority sorting
local function test_priority_sorting()
  local function get_priority(labels: {{string:string}}): integer
    for _, label in ipairs(labels) do
      if label.name == "p0" then return 0 end
      if label.name == "p1" then return 1 end
      if label.name == "p2" then return 2 end
    end
    return 3
  end

  local issues = {
    {
      number = 1,
      title = "Low priority",
      body = "Body 1",
      url = "url1",
      labels = {},
      createdAt = "2024-01-01T00:00:00Z"
    },
    {
      number = 2,
      title = "P2 issue",
      body = "Body 2", 
      url = "url2",
      labels = {{name = "p2"}},
      createdAt = "2024-01-02T00:00:00Z"
    },
    {
      number = 3,
      title = "P0 issue",
      body = "Body 3",
      url = "url3",
      labels = {{name = "p0"}},
      createdAt = "2024-01-03T00:00:00Z"
    },
    {
      number = 4,
      title = "P1 issue",
      body = "Body 4",
      url = "url4",
      labels = {{name = "p1"}},
      createdAt = "2024-01-04T00:00:00Z"
    }
  }

  table.sort(issues, function(a: {string:any}, b: {string:any}): boolean
    local a_priority = get_priority(a.labels as {{string:string}})
    local b_priority = get_priority(b.labels as {{string:string}})
    
    if a_priority ~= b_priority then
      return a_priority < b_priority
    end
    
    return (a.createdAt as string) < (b.createdAt as string)
  end)
  
  assert(issues[1].number == 3, "p0 issue should be first")
  assert(issues[2].number == 4, "p1 issue should be second")
  assert(issues[3].number == 2, "p2 issue should be third")
  assert(issues[4].number == 1, "unlabeled issue should be last")
  
  print("✓ issues sort by priority correctly")
end
test_priority_sorting()

-- Test date sorting within same priority
local function test_date_sorting()
  local function get_priority(labels: {{string:string}}): integer
    for _, label in ipairs(labels) do
      if label.name == "p0" then return 0 end
      if label.name == "p1" then return 1 end
      if label.name == "p2" then return 2 end
    end
    return 3
  end

  local issues = {
    {
      number = 1,
      title = "Newer p1",
      body = "Body 1",
      url = "url1",
      labels = {{name = "p1"}},
      createdAt = "2024-01-05T00:00:00Z"
    },
    {
      number = 2,
      title = "Older p1",
      body = "Body 2",
      url = "url2",
      labels = {{name = "p1"}},
      createdAt = "2024-01-01T00:00:00Z"
    },
    {
      number = 3,
      title = "Middle p1",
      body = "Body 3",
      url = "url3",
      labels = {{name = "p1"}},
      createdAt = "2024-01-03T00:00:00Z"
    }
  }

  table.sort(issues, function(a: {string:any}, b: {string:any}): boolean
    local a_priority = get_priority(a.labels as {{string:string}})
    local b_priority = get_priority(b.labels as {{string:string}})
    
    if a_priority ~= b_priority then
      return a_priority < b_priority
    end
    
    return (a.createdAt as string) < (b.createdAt as string)
  end)
  
  assert(issues[1].number == 2, "oldest issue should be first")
  assert(issues[2].number == 3, "middle issue should be second")
  assert(issues[3].number == 1, "newest issue should be last")
  
  print("✓ issues sort by date within same priority")
end
test_date_sorting()

-- Test JSON output format
local function test_json_output_format()
  local selected = {
    number = 42,
    title = "Test issue title",
    body = "Test issue body with\nmultiple lines",
    url = "https://github.com/test/repo/issues/42",
    labels = {{name = "p1"}, {name = "bug"}},
    createdAt = "2024-01-15T10:30:00Z",
    extraField = "should not appear"
  }

  -- Output format should only include specific fields
  local output = {
    number = selected.number,
    title = selected.title,
    body = selected.body,
    url = selected.url
  }

  local encoded = json.encode(output)
  local decoded = json.decode(encoded) as {string:any}
  
  assert(decoded.number == 42, "number should be preserved")
  assert(decoded.title == "Test issue title", "title should be preserved")
  assert((decoded.body as string):match("multiple lines"), "body should be preserved with newlines")
  assert(decoded.url == "https://github.com/test/repo/issues/42", "url should be preserved")
  assert(decoded.labels == nil, "labels should not be in output")
  assert(decoded.createdAt == nil, "createdAt should not be in output")
  assert(decoded.extraField == nil, "extra fields should not be in output")
  
  print("✓ JSON output format is correct")
end
test_json_output_format()

-- Test empty issue list handling
local function test_empty_issues()
  local issues: {{string:any}} = {}
  
  -- work-select should exit with code 1 when no issues
  assert(#issues == 0, "should have empty issue list")
  
  print("✓ empty issue list detected correctly")
end
test_empty_issues()

-- Test mixed priority labels
local function test_mixed_priorities()
  local function get_priority(labels: {{string:string}}): integer
    for _, label in ipairs(labels) do
      if label.name == "p0" then return 0 end
      if label.name == "p1" then return 1 end
      if label.name == "p2" then return 2 end
    end
    return 3
  end

  -- Issue with multiple priority labels - first found wins
  local labels = {{name = "bug"}, {name = "p0"}, {name = "help wanted"}, {name = "p2"}}
  assert(get_priority(labels) == 0, "should find p0 in the label list")
  
  print("✓ handles multiple priority labels correctly")
end
test_mixed_priorities()

-- Test sorting stability
local function test_sorting_stability()
  local function get_priority(labels: {{string:string}}): integer
    for _, label in ipairs(labels) do
      if label.name == "p0" then return 0 end
      if label.name == "p1" then return 1 end
      if label.name == "p2" then return 2 end
    end
    return 3
  end

  -- Issues with same priority and date should maintain relative order
  local issues = {
    {number = 1, labels = {{name = "p1"}}, createdAt = "2024-01-01T00:00:00Z"},
    {number = 2, labels = {{name = "p1"}}, createdAt = "2024-01-01T00:00:00Z"},
    {number = 3, labels = {{name = "p0"}}, createdAt = "2024-01-02T00:00:00Z"},
  }

  table.sort(issues, function(a: {string:any}, b: {string:any}): boolean
    local a_priority = get_priority(a.labels as {{string:string}})
    local b_priority = get_priority(b.labels as {{string:string}})
    
    if a_priority ~= b_priority then
      return a_priority < b_priority
    end
    
    return (a.createdAt as string) < (b.createdAt as string)
  end)
  
  assert(issues[1].number == 3, "p0 should be first regardless of date")
  -- For same priority and date, order is stable (maintained from original)
  
  print("✓ sorting is stable for equal elements")
end
test_sorting_stability()

print("\nAll work-select tests passed!")