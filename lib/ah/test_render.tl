#!/usr/bin/env cosmic
-- test_render.tl: tests for ah.render markdown-to-ANSI renderer

local record Render
  render_markdown: function(text: string): string
  apply_inline: function(line: string): string
  colorize_diff_line: function(line: string): string
end

local render = require("ah.render") as Render

local BOLD = "\27[1m"
local DIM = "\27[2m"
local RESET = "\27[0m"

-- test: h1 heading renders bold
local function test_h1_heading()
  local result = render.render_markdown("# Hello\n")
  assert(result:find(BOLD .. "# Hello" .. RESET, 1, true),
    "h1 should be bold, got: " .. result)
  print("PASS: h1 heading renders bold")
end

-- test: h2 heading renders bold
local function test_h2_heading()
  local result = render.render_markdown("## Section\n")
  assert(result:find(BOLD .. "## Section" .. RESET, 1, true),
    "h2 should be bold, got: " .. result)
  print("PASS: h2 heading renders bold")
end

-- test: h3 heading renders bold
local function test_h3_heading()
  local result = render.render_markdown("### Sub\n")
  assert(result:find(BOLD .. "### Sub" .. RESET, 1, true),
    "h3 should be bold, got: " .. result)
  print("PASS: h3 heading renders bold")
end

-- test: **bold** renders with bold ANSI
local function test_bold()
  local result = render.render_markdown("some **bold** text\n")
  assert(result:find(BOLD .. "bold" .. RESET, 1, true),
    "bold should have ANSI bold, got: " .. result)
  print("PASS: **bold** renders with bold ANSI")
end

-- test: `code` renders with dim ANSI
local function test_inline_code()
  local result = render.render_markdown("use `foo` here\n")
  assert(result:find(DIM .. "foo" .. RESET, 1, true),
    "inline code should be dim, got: " .. result)
  print("PASS: `code` renders with dim ANSI")
end

-- test: code fence lines pass through unchanged
local function test_code_fence()
  local input = "```lua\nlocal x = 1\n```\n"
  local result = render.render_markdown(input)
  assert(result:find("local x = 1", 1, true),
    "code fence content should pass through, got: " .. result)
  -- Should NOT apply inline formatting inside fences
  assert(not result:find(BOLD, 1, true),
    "code fence content should not have bold")
  assert(not result:find(DIM, 1, true),
    "code fence content should not have dim")
  print("PASS: code fence lines pass through unchanged")
end

-- test: diff fence lines are colorized
local function test_diff_fence()
  local input = "```diff\n+added\n-removed\n@@hunk@@\n```\n"
  local result = render.render_markdown(input)
  assert(result:find("\27[34m+added\27[0m", 1, true),
    "diff + line should be blue, got: " .. result)
  assert(result:find("\27[33m-removed\27[0m", 1, true),
    "diff - line should be yellow, got: " .. result)
  assert(result:find("\27[36m@@hunk@@\27[0m", 1, true),
    "diff @@ line should be cyan, got: " .. result)
  print("PASS: diff fence lines are colorized")
end

-- test: horizontal rule renders as dim dashes
local function test_horizontal_rule()
  local result = render.render_markdown("---\n")
  assert(result:find(DIM, 1, true), "hr should have dim, got: " .. result)
  assert(result:find("─", 1, true), "hr should have dash char, got: " .. result)
  assert(result:find(RESET, 1, true), "hr should have reset, got: " .. result)
  print("PASS: horizontal rule renders as dim dashes")
end

-- test: plain text passes through unchanged
local function test_plain_text()
  local input = "just some plain text\n"
  local result = render.render_markdown(input)
  assert(result:find("just some plain text", 1, true),
    "plain text should pass through, got: " .. result)
  assert(not result:find(BOLD, 1, true), "plain text should not have bold")
  assert(not result:find(DIM, 1, true), "plain text should not have dim")
  print("PASS: plain text passes through unchanged")
end

-- test: heading with inline code
local function test_heading_with_code()
  -- Headings are fully bolded, inline code not separately applied
  local result = render.render_markdown("# Using `foo`\n")
  assert(result:find(BOLD .. "# Using `foo`" .. RESET, 1, true),
    "heading with code should be fully bold, got: " .. result)
  print("PASS: heading with inline code renders correctly")
end

-- test: multiple paragraphs
local function test_multiple_paragraphs()
  local input = "# Title\n\nsome **bold** here\n\n## Next\n\nplain text\n"
  local result = render.render_markdown(input)
  assert(result:find(BOLD .. "# Title" .. RESET, 1, true),
    "title should be bold")
  assert(result:find(BOLD .. "bold" .. RESET, 1, true),
    "bold should render")
  assert(result:find(BOLD .. "## Next" .. RESET, 1, true),
    "second heading should be bold")
  print("PASS: multiple paragraphs render correctly")
end

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
  assert(render.colorize_diff_line("--- a/file") == "\27[1m--- a/file\27[0m",
    "--- line should be bold")
  assert(render.colorize_diff_line("+++ b/file") == "\27[1m+++ b/file\27[0m",
    "+++ line should be bold")
  print("PASS: colorize_diff_line works correctly")
end

-- test: apply_inline directly
local function test_apply_inline()
  local result = render.apply_inline("hello **world** and `code`")
  assert(result:find(BOLD .. "world" .. RESET, 1, true),
    "bold should work in apply_inline")
  assert(result:find(DIM .. "code" .. RESET, 1, true),
    "code should work in apply_inline")
  print("PASS: apply_inline works correctly")
end

-- test: underscore and asterisk horizontal rules
local function test_hr_variants()
  local r1 = render.render_markdown("___\n")
  assert(r1:find(DIM, 1, true), "___ should render as hr")
  local r2 = render.render_markdown("***\n")
  assert(r2:find(DIM, 1, true), "*** should render as hr")
  print("PASS: horizontal rule variants render correctly")
end

-- test: code fence does not apply bold inside
local function test_no_bold_in_fence()
  local input = "```\nsome **bold** text\n```\n"
  local result = render.render_markdown(input)
  assert(result:find("some **bold** text", 1, true),
    "bold markers should be preserved inside fence")
  assert(not result:find(BOLD .. "bold" .. RESET, 1, true),
    "bold ANSI should not appear inside fence")
  print("PASS: no bold formatting inside code fence")
end

test_h1_heading()
test_h2_heading()
test_h3_heading()
test_bold()
test_inline_code()
test_code_fence()
test_diff_fence()
test_horizontal_rule()
test_plain_text()
test_heading_with_code()
test_multiple_paragraphs()
test_colorize_diff_line()
test_apply_inline()
test_hr_variants()
test_no_bold_in_fence()
