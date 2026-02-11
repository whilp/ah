#!/usr/bin/env cosmic
-- test_work_labels.tl: tests for work label management

local record Work
  required_labels: {string}
  ensure_labels: function(string): boolean, string
end

local work = require("ah.work") as Work

-- Test that required_labels exists and contains expected labels
local function test_required_labels()
  assert(work.required_labels ~= nil, "required_labels should be exported")
  local expected = {"todo", "doing", "done", "failed", "friction"}
  local found: {string:boolean} = {}
  for _, label in ipairs(work.required_labels) do
    found[label] = true
  end

  for _, label in ipairs(expected) do
    assert(found[label], "required_labels should contain '" .. label .. "'")
  end

  assert(#work.required_labels == #expected,
    "required_labels should have exactly " .. #expected .. " labels, got " .. #work.required_labels)
  print("✓ required_labels contains all expected labels")
end
test_required_labels()

-- Test that ensure_labels is exported as a function
local function test_ensure_labels_exported()
  assert(type(work.ensure_labels) == "function", "ensure_labels should be exported as a function")
  print("✓ ensure_labels is exported")
end
test_ensure_labels_exported()

print("\nAll work-labels tests passed!")
