#!/usr/bin/env cosmic
-- test_render.tl: tests for ah.render ANSI helpers and text utilities

local record Render
  colorize_diff_line: function(line: string): string
  display_width: function(s: string): integer
  utf8_truncate: function(s: string, max_chars: integer, suffix: string): string
end

local render = require("ah.render") as Render

local BOLD = "\27[1m"
local RESET = "\27[0m"

-- test: colorize_diff_line directly
local function test_colorize_diff_line()
  assert(render.colorize_diff_line("+add") == "\27[34m+add\27[0m",
    "+ line should be blue")
  assert(render.colorize_diff_line("-del") == "\27[33m-del\27[0m",
    "- line should be yellow")
  assert(render.colorize_diff_line("@@ -1,2 +3,4 @@") == "\27[36m@@ -1,2 +3,4 @@\27[0m",
    "@@ line should be cyan")
  assert(render.colorize_diff_line("context") == "context",
    "context line should be unchanged")
  assert(render.colorize_diff_line("--- a/file") == BOLD .. "--- a/file" .. RESET,
    "--- line should be bold")
  assert(render.colorize_diff_line("+++ b/file") == BOLD .. "+++ b/file" .. RESET,
    "+++ line should be bold")
  print("PASS: colorize_diff_line works correctly")
end

-- test: display_width counts UTF-8 characters not bytes
local function test_display_width()
  assert(render.display_width("hello") == 5, "ASCII should be 5")
  assert(render.display_width("café") == 4, "café should be 4 chars, not 5 bytes")
  assert(render.display_width("日本語") == 3, "3 CJK chars")
  assert(render.display_width("a\27[1mb\27[0mc") == 3, "ANSI codes should be stripped")
  assert(render.display_width("") == 0, "empty string")
  print("PASS: display_width counts UTF-8 characters not bytes")
end

-- test: utf8_truncate never splits multi-byte sequences
local function test_utf8_truncate()
  assert(render.utf8_truncate("hello", 3, "...") == "hel...", "ASCII truncate")
  assert(render.utf8_truncate("hi", 10, "...") == "hi", "no truncate when short")
  assert(render.utf8_truncate("café", 3, "...") == "caf...", "truncate before é")
  assert(render.utf8_truncate("café", 4, "...") == "café", "exact length no truncate")
  -- Verify no broken UTF-8
  local result = render.utf8_truncate("aübcd", 3, "…")
  assert(result == "aüb…", "should not split ü, got: " .. result)
  print("PASS: utf8_truncate never splits multi-byte sequences")
end

test_colorize_diff_line()
test_display_width()
test_utf8_truncate()
