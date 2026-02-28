-- ah/render.tl: line-oriented markdown-to-ANSI renderer for terminal output
-- Converts common markdown constructs to ANSI escape sequences.
-- Handles headings, bold, inline code, code fences (with diff colorization),
-- horizontal rules, and tables with box-drawing borders.

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

-- Check if a line looks like a markdown table row (starts and ends with |).
local function is_table_line(line: string): boolean
  local trimmed = line:match("^%s*(.-)%s*$")
  return trimmed:sub(1, 1) == "|" and trimmed:sub(-1) == "|"
end

-- Check if a line is a table separator row (e.g. |---|---|).
local function is_separator_line(line: string): boolean
  local trimmed = line:match("^%s*(.-)%s*$")
  return trimmed:match("^|[%-|:%s]+|%s*$") ~= nil
end

-- Parse a table row into cells (trimmed content between pipes).
local function parse_row(line: string): {string}
  local cells: {string} = {}
  local trimmed = line:match("^%s*(.-)%s*$")
  -- Strip leading and trailing pipes
  local inner = trimmed:sub(2, -2)
  for cell in inner:gmatch("([^|]*)") do
    table.insert(cells, cell:match("^%s*(.-)%s*$"))
  end
  return cells
end

-- Compute display width of a string, stripping ANSI escape sequences.
local function display_width(s: string): integer
  local stripped = s:gsub("\27%[[%d;]*m", "")
  return #stripped
end

-- Render a table block from raw markdown lines into box-drawing output.
-- Returns a list of rendered lines.
local function render_table(lines: {string}): {string}
  -- Parse all rows, detecting separator
  local rows: {{string}} = {}
  local sep_index = 0
  for i, line in ipairs(lines) do
    if is_separator_line(line) and i == 2 then
      sep_index = i
    else
      table.insert(rows, parse_row(line))
    end
  end

  if #rows == 0 then
    return lines
  end

  -- Determine column count (max across all rows)
  local num_cols = 0
  for _, row in ipairs(rows) do
    if #row > num_cols then
      num_cols = #row
    end
  end

  -- Compute column widths (max cell display width per column)
  local widths: {integer} = {}
  for c = 1, num_cols do
    widths[c] = 0
  end
  for _, row in ipairs(rows) do
    for c = 1, num_cols do
      local cell = row[c] or ""
      local w = display_width(cell)
      if w > widths[c] then
        widths[c] = w
      end
    end
  end

  -- Ensure minimum width of 1
  for c = 1, num_cols do
    if widths[c] < 1 then
      widths[c] = 1
    end
  end

  -- Build horizontal border line
  local function hline(left: string, mid: string, right: string, fill: string): string
    local parts: {string} = {left}
    for c = 1, num_cols do
      table.insert(parts, string.rep(fill, widths[c] + 2))
      if c < num_cols then
        table.insert(parts, mid)
      end
    end
    table.insert(parts, right)
    return table.concat(parts)
  end

  -- Build data row with optional bold and inline formatting
  local function data_row(cells: {string}, bold: boolean): string
    local parts: {string} = {"│"}
    for c = 1, num_cols do
      local cell = cells[c] or ""
      local padded = " " .. cell .. string.rep(" ", widths[c] - display_width(cell)) .. " "
      if bold then
        padded = BOLD .. padded .. RESET
      else
        padded = apply_inline(padded)
      end
      table.insert(parts, padded)
      table.insert(parts, "│")
    end
    return table.concat(parts)
  end

  local out: {string} = {}

  -- Top border
  table.insert(out, hline("┌", "┬", "┐", "─"))

  -- Header row (if separator was found)
  if sep_index > 0 and #rows >= 1 then
    table.insert(out, data_row(rows[1], true))
    -- Header separator
    table.insert(out, hline("├", "┼", "┤", "─"))
    -- Body rows
    for r = 2, #rows do
      table.insert(out, data_row(rows[r], false))
    end
  else
    -- No header, all body rows
    for _, row in ipairs(rows) do
      table.insert(out, data_row(row, false))
    end
  end

  -- Bottom border
  table.insert(out, hline("└", "┴", "┘", "─"))

  return out
end

-- Render markdown text to ANSI-escaped text for terminal display.
-- Processes text line-by-line, tracking code fence and table state.
local function render_markdown(text: string): string
  local result: {string} = {}
  local in_code_fence = false
  local fence_lang = ""
  local table_buf: {string} = {}

  -- Flush accumulated table lines through render_table
  local function flush_table()
    if #table_buf > 0 then
      local rendered = render_table(table_buf)
      for _, l in ipairs(rendered) do
        table.insert(result, l)
      end
      table_buf = {}
    end
  end

  for line in text:gmatch("([^\n]*)\n?") do
    if not in_code_fence then
      -- Check for table line (outside code fences)
      if is_table_line(line) then
        table.insert(table_buf, line)
      else
        -- Flush any buffered table before processing non-table line
        flush_table()

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

  -- Flush any remaining table at end of input
  flush_table()

  return table.concat(result, "\n")
end

return {
  render_markdown = render_markdown,
  apply_inline = apply_inline,
  colorize_diff_line = colorize_diff_line,
  render_table = render_table,
}
