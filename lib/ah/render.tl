-- ah/render.tl: ANSI helpers and text utilities for terminal output

local BOLD = "\27[1m"
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

-- Compute display width of a string, stripping ANSI escape sequences
-- and counting UTF-8 characters (not bytes).
local function display_width(s: string): integer
  local stripped = s:gsub("\27%[[%d;]*m", "")
  local len = 0
  local i = 1
  while i <= #stripped do
    local b = stripped:byte(i)
    if b < 0x80 then
      i = i + 1
    elseif b < 0xE0 then
      i = i + 2
    elseif b < 0xF0 then
      i = i + 3
    else
      i = i + 4
    end
    len = len + 1
  end
  return len
end

-- Truncate a string to at most max_chars UTF-8 characters, appending suffix
-- if truncated. Safe: never splits a multi-byte sequence.
local function utf8_truncate(s: string, max_chars: integer, suffix: string): string
  suffix = suffix or "..."
  local char_count = 0
  local i = 1
  while i <= #s do
    local b = s:byte(i)
    local seq_len = 1
    if b >= 0xF0 then
      seq_len = 4
    elseif b >= 0xE0 then
      seq_len = 3
    elseif b >= 0xC0 then
      seq_len = 2
    end
    char_count = char_count + 1
    if char_count > max_chars then
      return s:sub(1, i - 1) .. suffix
    end
    i = i + seq_len
  end
  return s
end

return {
  colorize_diff_line = colorize_diff_line,
  display_width = display_width,
  utf8_truncate = utf8_truncate,
}
