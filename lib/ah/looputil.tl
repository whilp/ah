-- ah/looputil.tl: utility functions for the agent loop
local json = require("cosmic.json")
local cfs = require("cosmic.fs")

-- Shorten an absolute path to a relative one when under cwd
local _cwd: string
local function shorten_path(p: string): string
  if not _cwd then
    _cwd = cfs.getcwd() or ""
  end
  if _cwd ~= "" and p:sub(1, #_cwd) == _cwd then
    local rest = p:sub(#_cwd + 1)
    if rest:sub(1, 1) == "/" then
      rest = rest:sub(2)
    end
    if rest == "" then return "." end
    return rest
  end
  return p
end

-- Extract key parameter from tool details or input for display
local function tool_key_param(tool_name: string, tool_input: string, details_json: string): string
  -- Try details first (structured data from tool execution)
  if details_json then
    local details = json.decode(details_json) as {string: any}
    if details then
      -- skill tool: show "source → name, N lines"
      if details.skill_name and details.line_count then
        local src = details.path and shorten_path(details.path as string) or "?"
        return string.format("%s → %s, %d lines", src, details.skill_name as string, details.line_count as integer)
      elseif details.path then
        return shorten_path(details.path as string)
      elseif details.command then
        local cmd = details.command as string
        local first_line = cmd:match("^([^\n]+)")
        if first_line and first_line ~= cmd then
          return first_line .. " ..."
        end
        return cmd
      end
    end
  end

  -- Fall back to parsing tool_input JSON
  if not tool_input then return "" end
  local input = json.decode(tool_input) as {string: any}
  if not input then return "" end

  if tool_name == "read" or tool_name == "write" or tool_name == "edit" then
    return shorten_path((input.path or "") as string)
  elseif tool_name == "bash" then
    local cmd = (input.command or "") as string
    local first_line = cmd:match("^([^\n]+)")
    if first_line and first_line ~= cmd then
      return first_line .. " ..."
    end
    return cmd
  end
  return ""
end

-- Wrap a long command at flag boundaries with \ continuations.
-- Returns cmd unchanged if it fits within width.
-- Otherwise splits at spaces before -- or - flags, joining with \<newline> + indent.
-- Falls back to splitting at any space if no flag boundaries found.
local function wrap_command(cmd: string, width: integer, indent: string): string
  width = width or 80
  indent = indent or "    "
  if #cmd <= width and not cmd:find(" #") then
    return cmd
  end

  -- Try splitting at comment/flag boundaries
  local parts: {string} = {}
  local current = ""
  for token in cmd:gmatch("%S+") do
    local is_comment = token:sub(1, 1) == "#" and current ~= ""
    local is_flag = #parts > 0 and token:sub(1, 1) == "-" and #current + 1 + #token > width
    if is_comment or is_flag then
      table.insert(parts, current)
      current = indent .. token
    elseif current == "" then
      current = token
    else
      local candidate = current .. " " .. token
      if #candidate > width and #parts > 0 then
        -- Even without a flag boundary, line is too long
        table.insert(parts, current)
        current = indent .. token
      else
        current = candidate
      end
    end
  end
  if current ~= "" then
    table.insert(parts, current)
  end

  if #parts > 1 then
    return table.concat(parts, " \\\n")
  end

  -- Fallback: split at any space boundary near the width
  parts = {}
  current = ""
  for token in cmd:gmatch("%S+") do
    if current == "" then
      current = token
    elseif #current + 1 + #token > width then
      table.insert(parts, current)
      current = indent .. token
    else
      current = current .. " " .. token
    end
  end
  if current ~= "" then
    table.insert(parts, current)
  end

  if #parts > 1 then
    return table.concat(parts, " \\\n")
  end

  return cmd
end

-- Compute a turn signature from a list of tool calls.
-- The signature captures the tool names and key parameters to identify
-- repetitive patterns across turns. For edit operations, includes the full
-- old_string and new_string to distinguish edits to the same file.
local function turn_signature(tool_calls: {any}): string
  local parts: {string} = {}
  for _, tool_call in ipairs(tool_calls) do
    local tc = tool_call as {string: any}
    local input = (tc.input or {}) as {string: any}
    local input_json = json.encode(input)
    local key = tool_key_param(tc.name as string, input_json, nil)
    -- For edit tool, append old_string and new_string to avoid collisions
    -- when multiple edits target the same file with different content.
    if tc.name == "edit" and input then
      local old_s = (input.old_string or "") as string
      local new_s = (input.new_string or "") as string
      key = key .. "|" .. old_s .. "|" .. new_s
    end
    table.insert(parts, (tc.name as string) .. ":" .. key)
  end
  return table.concat(parts, "|")
end

-- Check for consecutive identical signatures at the end of the history.
-- Returns the count of consecutive identical entries (1 = no repetition).
local function check_loop(history: {string}): integer
  if #history < 2 then return #history end
  local current = history[#history]
  local count = 1
  for i = #history - 1, 1, -1 do
    if history[i] == current then
      count = count + 1
    else
      break
    end
  end
  return count
end

return {
  shorten_path = shorten_path,
  tool_key_param = tool_key_param,
  wrap_command = wrap_command,
  turn_signature = turn_signature,
  check_loop = check_loop,
}
