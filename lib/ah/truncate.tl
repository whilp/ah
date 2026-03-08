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

-- Sanitize non-UTF-8 bytes by replacing them with the Unicode replacement
-- character (U+FFFD). Acts as a safety net to prevent invalid JSON when
-- binary content slips past tool-level checks.
local function sanitize_utf8(s: string): string, boolean
  local out: {string} = {}
  local changed = false
  local i = 1
  local len = #s
  while i <= len do
    local b = s:byte(i)
    if b < 0x80 then
      -- ASCII
      table.insert(out, s:sub(i, i))
      i = i + 1
    elseif b >= 0xC2 and b <= 0xDF then
      -- 2-byte sequence
      if i + 1 <= len then
        local b2 = s:byte(i + 1)
        if b2 >= 0x80 and b2 <= 0xBF then
          table.insert(out, s:sub(i, i + 1))
          i = i + 2
        else
          table.insert(out, "\xEF\xBF\xBD")
          changed = true
          i = i + 1
        end
      else
        table.insert(out, "\xEF\xBF\xBD")
        changed = true
        i = i + 1
      end
    elseif b >= 0xE0 and b <= 0xEF then
      -- 3-byte sequence
      if i + 2 <= len then
        local b2 = s:byte(i + 1)
        local b3 = s:byte(i + 2)
        local valid = b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF
        if b == 0xE0 then valid = valid and b2 >= 0xA0 end
        if b == 0xED then valid = valid and b2 <= 0x9F end
        if valid then
          table.insert(out, s:sub(i, i + 2))
          i = i + 3
        else
          table.insert(out, "\xEF\xBF\xBD")
          changed = true
          i = i + 1
        end
      else
        table.insert(out, "\xEF\xBF\xBD")
        changed = true
        i = i + 1
      end
    elseif b >= 0xF0 and b <= 0xF4 then
      -- 4-byte sequence
      if i + 3 <= len then
        local b2 = s:byte(i + 1)
        local b3 = s:byte(i + 2)
        local b4 = s:byte(i + 3)
        local valid = b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF and b4 >= 0x80 and b4 <= 0xBF
        if b == 0xF0 then valid = valid and b2 >= 0x90 end
        if b == 0xF4 then valid = valid and b2 <= 0x8F end
        if valid then
          table.insert(out, s:sub(i, i + 3))
          i = i + 4
        else
          table.insert(out, "\xEF\xBF\xBD")
          changed = true
          i = i + 1
        end
      else
        table.insert(out, "\xEF\xBF\xBD")
        changed = true
        i = i + 1
      end
    else
      -- Invalid leading byte (0x80-0xBF, 0xC0-0xC1, 0xF5-0xFF)
      table.insert(out, "\xEF\xBF\xBD")
      changed = true
      i = i + 1
    end
  end
  return table.concat(out), changed
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

  -- Safety net: replace any non-UTF-8 bytes that survived tool-level checks.
  -- This prevents invalid JSON when binary content reaches the API.
  result = sanitize_utf8(result)

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
  sanitize_utf8 = sanitize_utf8,
  count_lines = count_lines,
  TruncateResult = TruncateResult,
  DEFAULT_CHAR_LIMITS = DEFAULT_CHAR_LIMITS,
  DEFAULT_LINE_LIMITS = DEFAULT_LINE_LIMITS,
  DEFAULT_CHAR_LIMIT = DEFAULT_CHAR_LIMIT,
}
