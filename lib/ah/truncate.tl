-- ah/truncate.tl: output truncation for tool results
--
-- Truncates tool output before sending to the LLM while preserving full output
-- in the database and event stream. Two-pass approach: character-based truncation
-- first (primary size safeguard), then line-based truncation (readability pass).

local record TruncateResult
  content: string
  truncated: boolean
  original_bytes: integer
  original_lines: integer
end

-- Default per-tool character limits
local DEFAULT_CHAR_LIMITS: {string: integer} = {
  bash = 30000,
  read = 50000,
  write = 10000,
  edit = 10000,
}

-- Default per-tool line limits (applied after character truncation)
local DEFAULT_LINE_LIMITS: {string: integer} = {
  bash = 256,
}

-- Fallback limit for tools not in the table
local DEFAULT_CHAR_LIMIT = 30000

-- Count lines in a string
local function count_lines(s: string): integer
  if s == "" then return 0 end
  local n = 1
  for _ in s:gmatch("\n") do
    n = n + 1
  end
  return n
end

-- Truncate by characters using head/tail split: keep the beginning and end,
-- remove the middle. This preserves context (imports, setup) and results (final output).
local function truncate_chars(output: string, max_chars: integer): string, boolean
  if #output <= max_chars then
    return output, false
  end

  local half = math.floor(max_chars / 2)
  local removed = #output - max_chars
  local head = output:sub(1, half)
  local tail = output:sub(-half)

  return head
  .. "\n\n[output truncated: " .. tostring(removed) .. " bytes removed from middle]\n\n"
  .. tail, true
end

-- Truncate by line count using head/tail split: keep first and last lines.
local function truncate_lines(output: string, max_lines: integer): string, boolean
  local lines: {string} = {}
  for line in output:gmatch("([^\n]*)\n?") do
    table.insert(lines, line)
  end
  -- Remove trailing empty from gmatch
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end

  if #lines <= max_lines then
    return output, false
  end

  local head_count = math.floor(max_lines / 2)
  local tail_count = max_lines - head_count
  local omitted = #lines - head_count - tail_count

  local head_lines: {string} = {}
  for i = 1, head_count do
    table.insert(head_lines, lines[i])
  end

  local tail_lines: {string} = {}
  for i = #lines - tail_count + 1, #lines do
    table.insert(tail_lines, lines[i])
  end

  return table.concat(head_lines, "\n")
  .. "\n[..." .. tostring(omitted) .. " lines omitted...]\n"
  .. table.concat(tail_lines, "\n"), true
end

-- Truncate tool output: character-based first, then line-based.
-- Returns a TruncateResult with the (possibly truncated) content and metadata.
local function truncate_output(output: string, tool_name: string): TruncateResult
  local original_bytes: integer = #output
  local original_lines: integer = count_lines(output)

  local max_chars = DEFAULT_CHAR_LIMITS[tool_name] or DEFAULT_CHAR_LIMIT
  local result, char_truncated = truncate_chars(output, max_chars)

  local line_truncated = false
  local max_lines = DEFAULT_LINE_LIMITS[tool_name]
  if max_lines then
    result, line_truncated = truncate_lines(result, max_lines)
  end

  return {
    content = result,
    truncated = char_truncated or line_truncated,
    original_bytes = original_bytes,
    original_lines = original_lines,
  }
end

return {
  truncate_output = truncate_output,
  truncate_chars = truncate_chars,
  truncate_lines = truncate_lines,
  count_lines = count_lines,
  TruncateResult = TruncateResult,
  DEFAULT_CHAR_LIMITS = DEFAULT_CHAR_LIMITS,
  DEFAULT_LINE_LIMITS = DEFAULT_LINE_LIMITS,
  DEFAULT_CHAR_LIMIT = DEFAULT_CHAR_LIMIT,
}
