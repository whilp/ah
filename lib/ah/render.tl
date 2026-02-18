-- ah/render.tl: line-oriented markdown-to-ANSI renderer for terminal output
-- Converts common markdown constructs to ANSI escape sequences.
-- Handles headings, bold, inline code, code fences (with diff colorization),
-- and horizontal rules.

local BOLD = "\27[1m"
local DIM = "\27[2m"
local RESET = "\27[0m"

-- Colorize a single diff line with ANSI escape codes.
-- Uses blue/yellow instead of green/red for colorblind accessibility.
local function colorize_diff_line(line: string): string
  if line:sub(1, 3) == "+++" or line:sub(1, 3) == "---" then
    return BOLD .. line .. RESET
  elseif line:sub(1, 2) == "@@" then
    return "\27[36m" .. line .. RESET
  elseif line:sub(1, 1) == "+" then
    return "\27[34m" .. line .. RESET
  elseif line:sub(1, 1) == "-" then
    return "\27[33m" .. line .. RESET
  end
  return line
end

-- Apply inline markdown substitutions to a line.
-- Handles **bold** and `code` spans.
local function apply_inline(line: string): string
  -- Apply inline code first (more specific pattern)
  line = line:gsub("`([^`]+)`", DIM .. "%1" .. RESET)
  -- Apply bold
  line = line:gsub("%*%*(.-)%*%*", BOLD .. "%1" .. RESET)
  return line
end

-- Render markdown text to ANSI-escaped text for terminal display.
-- Processes text line-by-line, tracking code fence state.
local function render_markdown(text: string): string
  local result: {string} = {}
  local in_code_fence = false
  local fence_lang = ""

  for line in text:gmatch("([^\n]*)\n?") do
    if not in_code_fence then
      -- Check for fence open
      local lang = line:match("^```(.*)$")
      if lang then
        in_code_fence = true
        fence_lang = lang
        table.insert(result, line)
      elseif line:match("^#+ ") then
        -- Heading: bold the full line
        table.insert(result, BOLD .. line .. RESET)
      elseif line:match("^%-%-%-$") or line:match("^___$") or line:match("^%*%*%*$") then
        -- Horizontal rule: dim dashes
        table.insert(result, DIM .. string.rep("─", 40) .. RESET)
      else
        -- Regular line: apply inline formatting
        table.insert(result, apply_inline(line))
      end
    else
      -- Inside code fence
      if line:match("^```$") or line:match("^```%s") then
        -- Fence close
        in_code_fence = false
        fence_lang = ""
        table.insert(result, line)
      elseif fence_lang == "diff" then
        table.insert(result, colorize_diff_line(line))
      else
        table.insert(result, line)
      end
    end
  end

  return table.concat(result, "\n")
end

return {
  render_markdown = render_markdown,
  apply_inline = apply_inline,
  colorize_diff_line = colorize_diff_line,
}
