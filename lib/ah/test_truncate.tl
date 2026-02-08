#!/usr/bin/env cosmic
-- test_truncate.tl: tests for output truncation module
local truncate = require("ah.truncate")

-- count_lines tests
local function test_count_lines_empty()
  assert(truncate.count_lines("") == 0, "empty string should have 0 lines")
  print("✓ count_lines empty")
end
test_count_lines_empty()

local function test_count_lines_one()
  assert(truncate.count_lines("hello") == 1, "single line should be 1")
  print("✓ count_lines single line")
end
test_count_lines_one()

local function test_count_lines_multiple()
  assert(truncate.count_lines("a\nb\nc") == 3, "three lines: " .. tostring(truncate.count_lines("a\nb\nc")))
  print("✓ count_lines multiple lines")
end
test_count_lines_multiple()

local function test_count_lines_trailing_newline()
  assert(truncate.count_lines("a\nb\n") == 3, "trailing newline counts: " .. tostring(truncate.count_lines("a\nb\n")))
  print("✓ count_lines trailing newline")
end
test_count_lines_trailing_newline()

-- truncate_chars tests
local function test_truncate_chars_short()
  local result, truncated = truncate.truncate_chars("hello", 100)
  assert(result == "hello", "short string unchanged")
  assert(not truncated, "should not be truncated")
  print("✓ truncate_chars no-op for short strings")
end
test_truncate_chars_short()

local function test_truncate_chars_exact()
  local s = string.rep("x", 100)
  local result, truncated = truncate.truncate_chars(s, 100)
  assert(result == s, "exact length unchanged")
  assert(not truncated, "should not be truncated")
  print("✓ truncate_chars exact length")
end
test_truncate_chars_exact()

local function test_truncate_chars_long()
  local s = string.rep("x", 1000)
  local result, truncated = truncate.truncate_chars(s, 200)
  assert(truncated, "should be truncated")
  assert(#result < 1000, "result should be shorter than original")
  assert(result:match("%[output truncated:"), "should have truncation notice")
  assert(result:match("800 bytes removed"), "should report bytes removed")
  -- Head and tail should be present
  assert(result:sub(1, 1) == "x", "head should be preserved")
  assert(result:sub(-1) == "x", "tail should be preserved")
  print("✓ truncate_chars long string")
end
test_truncate_chars_long()

local function test_truncate_chars_preserves_head_tail()
  -- Build distinct head and tail
  local head = string.rep("H", 50)
  local middle = string.rep("M", 200)
  local tail = string.rep("T", 50)
  local s = head .. middle .. tail
  local result, truncated = truncate.truncate_chars(s, 120)
  assert(truncated, "should be truncated")
  -- Result should start with Hs and end with Ts
  assert(result:sub(1, 10) == string.rep("H", 10), "head preserved")
  assert(result:sub(-10) == string.rep("T", 10), "tail preserved")
  assert(result:match("%[output truncated:"), "has truncation notice")
  print("✓ truncate_chars preserves head and tail")
end
test_truncate_chars_preserves_head_tail()

-- truncate_lines tests
local function test_truncate_lines_short()
  local result, truncated = truncate.truncate_lines("a\nb\nc", 10)
  assert(result == "a\nb\nc", "short unchanged")
  assert(not truncated, "should not be truncated")
  print("✓ truncate_lines no-op for few lines")
end
test_truncate_lines_short()

local function test_truncate_lines_long()
  local lines = {}
  for i = 1, 20 do
    table.insert(lines, "line" .. tostring(i))
  end
  local s = table.concat(lines, "\n")
  local result, truncated = truncate.truncate_lines(s, 10)
  assert(truncated, "should be truncated")
  -- First 5 lines preserved
  assert(result:match("^line1\n"), "first line preserved")
  assert(result:match("line5\n"), "fifth line preserved")
  -- Last 5 lines preserved
  assert(result:match("line16\n"), "line 16 preserved")
  assert(result:match("line20"), "last line preserved")
  -- Omission notice
  assert(result:match("%[%.%.%.10 lines omitted%.%.%.%]"), "omission notice: " .. result)
  print("✓ truncate_lines head/tail split")
end
test_truncate_lines_long()

local function test_truncate_lines_exact()
  local lines = {}
  for i = 1, 10 do
    table.insert(lines, "line" .. tostring(i))
  end
  local s = table.concat(lines, "\n")
  local result, truncated = truncate.truncate_lines(s, 10)
  assert(not truncated, "exact count should not truncate")
  print("✓ truncate_lines exact count")
end
test_truncate_lines_exact()

-- truncate_output integration tests
local function test_truncate_output_short()
  local r = truncate.truncate_output("hello world", "bash")
  assert(r.content == "hello world", "short output unchanged")
  assert(not r.truncated, "should not be truncated")
  assert(r.original_bytes == 11, "original bytes: " .. tostring(r.original_bytes))
  assert(r.original_lines == 1, "original lines: " .. tostring(r.original_lines))
  print("✓ truncate_output short string")
end
test_truncate_output_short()

local function test_truncate_output_bash_limit()
  -- bash limit is 30000 chars
  local s = string.rep("x", 40000)
  local r = truncate.truncate_output(s, "bash")
  assert(r.truncated, "should be truncated")
  assert(r.original_bytes == 40000, "original bytes preserved")
  assert(r.content:match("%[output truncated:"), "has char truncation notice")
  print("✓ truncate_output applies bash char limit")
end
test_truncate_output_bash_limit()

local function test_truncate_output_read_limit()
  -- read limit is 50000 chars
  local s = string.rep("x", 40000)
  local r = truncate.truncate_output(s, "read")
  assert(not r.truncated, "40K should not exceed read's 50K limit")

  local s2 = string.rep("x", 60000)
  local r2 = truncate.truncate_output(s2, "read")
  assert(r2.truncated, "60K should exceed read's 50K limit")
  print("✓ truncate_output applies read char limit")
end
test_truncate_output_read_limit()

local function test_truncate_output_unknown_tool()
  -- Unknown tools use DEFAULT_CHAR_LIMIT (30000)
  local s = string.rep("x", 40000)
  local r = truncate.truncate_output(s, "custom_tool")
  assert(r.truncated, "should truncate unknown tool at default limit")
  print("✓ truncate_output handles unknown tools")
end
test_truncate_output_unknown_tool()

local function test_truncate_output_bash_line_limit()
  -- bash has 256 line limit
  local lines = {}
  for i = 1, 300 do
    table.insert(lines, "line" .. tostring(i))
  end
  local s = table.concat(lines, "\n")
  local r = truncate.truncate_output(s, "bash")
  assert(r.truncated, "should be truncated by line limit")
  assert(r.content:match("lines omitted"), "has line omission notice")
  -- First and last lines preserved
  assert(r.content:match("line1\n"), "first line preserved")
  assert(r.content:match("line300"), "last line preserved")
  print("✓ truncate_output applies bash line limit")
end
test_truncate_output_bash_line_limit()

local function test_truncate_output_read_no_line_limit()
  -- read has no line limit, only char limit
  local lines = {}
  for i = 1, 300 do
    table.insert(lines, "L" .. tostring(i))
  end
  local s = table.concat(lines, "\n")
  local r = truncate.truncate_output(s, "read")
  assert(not r.truncated, "300 short lines should be under read's 50K char limit")
  assert(not r.content:match("lines omitted"), "no line truncation for read")
  print("✓ truncate_output read has no line limit")
end
test_truncate_output_read_no_line_limit()

local function test_truncate_output_empty()
  local r = truncate.truncate_output("", "bash")
  assert(r.content == "", "empty string unchanged")
  assert(not r.truncated, "empty not truncated")
  assert(r.original_bytes == 0, "0 bytes")
  assert(r.original_lines == 0, "0 lines")
  print("✓ truncate_output empty string")
end
test_truncate_output_empty()

local function test_truncate_chars_notice_content()
  -- Verify the notice shows correct byte count
  local s = string.rep("a", 500)
  local result, _ = truncate.truncate_chars(s, 200)
  assert(result:match("300 bytes removed from middle"), "notice should show 300 bytes removed: " .. result)
  print("✓ truncate_chars notice shows correct byte count")
end
test_truncate_chars_notice_content()

print("\nAll truncate tests passed!")
