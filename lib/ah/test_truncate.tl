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

local function test_truncate_chars_with_tool_use_id()
  local s = string.rep("x", 1000)
  local result, truncated = truncate.truncate_chars(s, 200, "toolu_abc123")
  assert(truncated, "should be truncated")
  assert(result:match('tool_use_id="toolu_abc123"'), "notice should include tool_use_id: " .. result)
  assert(result:match("result tool"), "notice should mention result tool: " .. result)
  print("✓ truncate_chars includes tool_use_id in notice")
end
test_truncate_chars_with_tool_use_id()

local function test_truncate_chars_without_tool_use_id()
  local s = string.rep("x", 1000)
  local result, truncated = truncate.truncate_chars(s, 200)
  assert(truncated, "should be truncated")
  assert(result:match("narrow the output"), "should show fallback hint: " .. result)
  assert(not result:match("result tool"), "should not mention result tool")
  print("✓ truncate_chars fallback notice without tool_use_id")
end
test_truncate_chars_without_tool_use_id()

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
  assert(result:match("%[%.%.%.10 lines omitted"), "omission notice: " .. result)
  print("✓ truncate_lines head/tail split")
end
test_truncate_lines_long()

local function test_truncate_lines_with_tool_use_id()
  local lines = {}
  for i = 1, 20 do
    table.insert(lines, "line" .. tostring(i))
  end
  local s = table.concat(lines, "\n")
  local result, truncated = truncate.truncate_lines(s, 10, "toolu_xyz789")
  assert(truncated, "should be truncated")
  assert(result:match('tool_use_id="toolu_xyz789"'), "notice should include tool_use_id: " .. result)
  assert(result:match("result tool"), "notice should mention result tool")
  print("✓ truncate_lines includes tool_use_id in notice")
end
test_truncate_lines_with_tool_use_id()

local function test_truncate_lines_without_tool_use_id()
  local lines = {}
  for i = 1, 20 do
    table.insert(lines, "line" .. tostring(i))
  end
  local s = table.concat(lines, "\n")
  local result, truncated = truncate.truncate_lines(s, 10)
  assert(truncated, "should be truncated")
  assert(result:match("narrow your command"), "fallback notice without tool_use_id: " .. result)
  print("✓ truncate_lines fallback notice without tool_use_id")
end
test_truncate_lines_without_tool_use_id()

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
  -- bash limit is 3000 chars
  local s = string.rep("x", 5000)
  local r = truncate.truncate_output(s, "bash")
  assert(r.truncated, "should be truncated")
  assert(r.original_bytes == 5000, "original bytes preserved")
  assert(r.content:match("%[output truncated:"), "has char truncation notice")
  print("✓ truncate_output applies bash char limit")
end
test_truncate_output_bash_limit()

local function test_truncate_output_read_limit()
  -- read limit is 4000 chars
  local s = string.rep("x", 3000)
  local r = truncate.truncate_output(s, "read")
  assert(not r.truncated, "3K should not exceed read's 4K limit")

  local s2 = string.rep("x", 6000)
  local r2 = truncate.truncate_output(s2, "read")
  assert(r2.truncated, "6K should exceed read's 4K limit")
  print("✓ truncate_output applies read char limit")
end
test_truncate_output_read_limit()

local function test_truncate_output_unknown_tool()
  -- Unknown tools use DEFAULT_CHAR_LIMIT (3000)
  local s = string.rep("x", 5000)
  local r = truncate.truncate_output(s, "custom_tool")
  assert(r.truncated, "should truncate unknown tool at default limit")
  print("✓ truncate_output handles unknown tools")
end
test_truncate_output_unknown_tool()

local function test_truncate_output_bash_line_limit()
  -- bash has a 100-line limit
  local lines = {}
  for i = 1, 80 do
    table.insert(lines, "L" .. tostring(i))
  end
  local s = table.concat(lines, "\n")
  local r = truncate.truncate_output(s, "bash")
  assert(not r.truncated, "80 short lines should not be truncated (under 100 line limit)")
  assert(not r.content:match("lines omitted"), "should have no line omission notice")

  -- Over the line limit
  local many_lines = {}
  for i = 1, 200 do
    table.insert(many_lines, "L" .. tostring(i))
  end
  local s2 = table.concat(many_lines, "\n")
  local r2 = truncate.truncate_output(s2, "bash")
  assert(r2.truncated, "200 lines should be truncated at 100 line limit")
  assert(r2.content:match("lines omitted"), "should have line omission notice")
  print("✓ truncate_output bash line limit")
end
test_truncate_output_bash_line_limit()

local function test_truncate_output_read_no_line_limit()
  -- read has no line limit, only char limit
  local lines = {}
  for i = 1, 100 do
    table.insert(lines, "L" .. tostring(i))
  end
  local s = table.concat(lines, "\n")
  local r = truncate.truncate_output(s, "read")
  assert(not r.truncated, "100 short lines should be under read's 4K char limit")
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

local function test_truncate_output_with_tool_use_id()
  local s = string.rep("x", 5000)
  local r = truncate.truncate_output(s, "bash", "toolu_test123")
  assert(r.truncated, "should be truncated")
  assert(r.content:match('tool_use_id="toolu_test123"'), "notice should include tool_use_id: " .. r.content)
  assert(r.content:match("result tool"), "notice should mention result tool")
  print("✓ truncate_output passes tool_use_id through")
end
test_truncate_output_with_tool_use_id()

local function test_truncate_output_no_truncation_no_tool_use_id()
  -- Even with a tool_use_id, no truncation = no tool_use_id in content
  local r = truncate.truncate_output("hello", "bash", "toolu_test123")
  assert(not r.truncated, "should not be truncated")
  assert(not r.content:match("result tool"), "no tool_use_id when not truncated")
  print("✓ truncate_output no tool_use_id injected when not truncated")
end
test_truncate_output_no_truncation_no_tool_use_id()

-- sanitize_utf8 tests
local function test_sanitize_utf8_ascii()
  local result, changed = truncate.sanitize_utf8("hello world")
  assert(result == "hello world", "ascii unchanged")
  assert(not changed, "no change for ascii")
  print("✓ sanitize_utf8 ascii passthrough")
end
test_sanitize_utf8_ascii()

local function test_sanitize_utf8_valid_multibyte()
  local s = "café résumé"
  local result, changed = truncate.sanitize_utf8(s)
  assert(result == s, "valid utf8 unchanged")
  assert(not changed, "no change for valid utf8")
  print("✓ sanitize_utf8 valid multibyte passthrough")
end
test_sanitize_utf8_valid_multibyte()

local function test_sanitize_utf8_invalid_bytes()
  -- 0x80 is an invalid leading byte (continuation byte without leader)
  local s = "hello\x80world"
  local result, changed = truncate.sanitize_utf8(s)
  assert(changed, "should detect invalid bytes")
  assert(result == "hello\xEF\xBF\xBDworld", "should replace with U+FFFD: got " .. result)
  print("✓ sanitize_utf8 replaces invalid bytes")
end
test_sanitize_utf8_invalid_bytes()

local function test_sanitize_utf8_null_byte()
  -- Null bytes are valid ASCII but let's verify they pass through
  local s = "hello\0world"
  local result, changed = truncate.sanitize_utf8(s)
  assert(result == s, "null byte is valid ascii")
  assert(not changed, "no change for null byte")
  print("✓ sanitize_utf8 null byte passthrough")
end
test_sanitize_utf8_null_byte()

local function test_sanitize_utf8_gzip_header()
  -- Simulate gzip magic bytes: 1f 8b 08 00
  local s = "\x1f\x8b\x08\x00binary data"
  local result, changed = truncate.sanitize_utf8(s)
  assert(changed, "gzip bytes should be replaced")
  assert(not result:find("\x8b"), "invalid bytes should be gone")
  print("✓ sanitize_utf8 handles gzip-like binary")
end
test_sanitize_utf8_gzip_header()

local function test_sanitize_utf8_truncated_sequence()
  -- 2-byte sequence leader at end of string (truncated)
  local s = "hello\xC3"
  local result, changed = truncate.sanitize_utf8(s)
  assert(changed, "truncated sequence should be replaced")
  assert(result == "hello\xEF\xBF\xBD", "should replace truncated sequence")
  print("✓ sanitize_utf8 handles truncated sequences")
end
test_sanitize_utf8_truncated_sequence()

local function test_sanitize_utf8_empty()
  local result, changed = truncate.sanitize_utf8("")
  assert(result == "", "empty string unchanged")
  assert(not changed, "no change for empty")
  print("✓ sanitize_utf8 empty string")
end
test_sanitize_utf8_empty()

local function test_sanitize_utf8_overlong()
  -- 0xC0 0x80 is an overlong encoding of NUL — should be rejected
  local s = "a\xC0\x80b"
  local result, changed = truncate.sanitize_utf8(s)
  assert(changed, "overlong should be replaced")
  -- 0xC0 is invalid leader (< 0xC2), 0x80 is continuation without leader
  assert(result:find("\xEF\xBF\xBD"), "should contain replacement char")
  print("✓ sanitize_utf8 rejects overlong encodings")
end
test_sanitize_utf8_overlong()

local function test_truncate_output_sanitizes()
  -- Verify truncate_output applies sanitization
  local s = "hello\x80world"
  local r = truncate.truncate_output(s, "bash")
  assert(r.content == "hello\xEF\xBF\xBDworld", "truncate_output should sanitize: got " .. r.content)
  print("✓ truncate_output sanitizes non-utf8")
end
test_truncate_output_sanitizes()

local function test_truncate_output_result_tool_would_truncate()
  -- The truncate module itself has no exemption for the result tool.
  -- Callers (looptool.tl, loop.tl) skip truncation when tc.name == "result".
  -- This test documents that the module truncates result tool output — the
  -- exemption is in the callers, not here.
  local s = string.rep("x", 5000)
  local r = truncate.truncate_output(s, "result")
  assert(r.truncated, "truncate module truncates result tool output (callers exempt it)")
  assert(r.content:match("%[output truncated:"), "has truncation notice")
  print("✓ truncate_output result tool would truncate without caller exemption")
end
test_truncate_output_result_tool_would_truncate()

print("\nAll truncate tests passed!")
