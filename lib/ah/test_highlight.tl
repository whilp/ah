#!/usr/bin/env cosmic
-- test_highlight.tl: tests for diff highlighting module
local highlight = require("ah.highlight")

local GREEN = "\27[32m"
local RED = "\27[31m"
local CYAN = "\27[36m"
local RESET = "\27[0m"

-- plain text passes through unchanged
local function test_plain_text()
  local input = "hello world\nno diff here\n"
  local result = highlight.colorize_diff(input, true)
  assert(result == input, "plain text should pass through unchanged")
  print("✓ plain text unchanged")
end
test_plain_text()

-- enabled=false returns text unchanged
local function test_disabled()
  local input = "```diff\n+added\n-removed\n```\n"
  local result = highlight.colorize_diff(input, false)
  assert(result == input, "disabled should return text unchanged")
  print("✓ disabled returns unchanged")
end
test_disabled()

-- empty/nil input
local function test_empty()
  assert(highlight.colorize_diff("", true) == "", "empty string")
  assert(highlight.colorize_diff(nil, true) == "", "nil input")
  print("✓ empty/nil input handled")
end
test_empty()

-- diff fence content is colorized
local function test_diff_colorized()
  local input = "```diff\n+added line\n-removed line\n@@ -1,3 +1,4 @@\n context\n```\n"
  local result = highlight.colorize_diff(input, true)
  assert(result:find(GREEN .. "+added line" .. RESET, 1, true), "added line should be green: " .. result)
  assert(result:find(RED .. "-removed line" .. RESET, 1, true), "removed line should be red: " .. result)
  assert(result:find(CYAN .. "@@ -1,3 +1,4 @@" .. RESET, 1, true), "hunk header should be cyan: " .. result)
  assert(result:find(" context", 1, true), "context line should be unchanged")
  print("✓ diff content colorized")
end
test_diff_colorized()

-- non-diff fences are not colorized
local function test_non_diff_fence()
  local input = "```python\n+not_colored\n-not_colored\n```\n"
  local result = highlight.colorize_diff(input, true)
  assert(result == input, "non-diff fence should not be colorized: " .. result)
  print("✓ non-diff fence unchanged")
end
test_non_diff_fence()

-- multiple diff blocks
local function test_multiple_blocks()
  local input = "text\n```diff\n+a\n```\nmiddle\n```diff\n-b\n```\nend\n"
  local result = highlight.colorize_diff(input, true)
  assert(result:find(GREEN .. "+a" .. RESET, 1, true), "first block colored")
  assert(result:find(RED .. "-b" .. RESET, 1, true), "second block colored")
  assert(result:find("middle", 1, true), "middle text unchanged")
  print("✓ multiple diff blocks")
end
test_multiple_blocks()

-- +++ and --- file headers are colored
local function test_file_headers()
  local input = "```diff\n--- a/file.txt\n+++ b/file.txt\n```\n"
  local result = highlight.colorize_diff(input, true)
  assert(result:find(RED .. "--- a/file.txt" .. RESET, 1, true), "--- header should be red: " .. result)
  assert(result:find(GREEN .. "+++ b/file.txt" .. RESET, 1, true), "+++ header should be green: " .. result)
  print("✓ file headers colored")
end
test_file_headers()

-- text without trailing newline
local function test_no_trailing_newline()
  local input = "```diff\n+line\n```"
  local result = highlight.colorize_diff(input, true)
  assert(not result:match("\n$"), "should not add trailing newline: [" .. result .. "]")
  assert(result:find(GREEN .. "+line" .. RESET, 1, true), "line should be colored")
  print("✓ no trailing newline preserved")
end
test_no_trailing_newline()

-- text with trailing newline
local function test_trailing_newline()
  local input = "```diff\n+line\n```\n"
  local result = highlight.colorize_diff(input, true)
  assert(result:match("\n$"), "should preserve trailing newline")
  print("✓ trailing newline preserved")
end
test_trailing_newline()

print("PASS")
