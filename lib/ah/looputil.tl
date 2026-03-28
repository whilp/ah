-- ah/looputil.tl: utility functions for the agent loop
local json = require("cosmic.json")
local cfs = require("cosmic.fs")
local events = require("ah.events")

local function emit(on_event: events.EventCallback, event: events.EventData)
  if on_event then on_event(event) end
end

-- Shorten an absolute path to a relative one when under cwd
local function shorten_path(p: string): string
  local cwd = cfs.getcwd() or ""
  if cwd ~= "" and p:sub(1, #cwd) == cwd then
    local rest = p:sub(#cwd + 1)
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
        local src = details.path and shorten_path(tostring(details.path)) or "?"
        return string.format("%s → %s, %d lines", src, tostring(details.skill_name), tonumber(details.line_count) as integer)
      elseif details.path then
        return shorten_path(tostring(details.path))
      elseif details.command then
        return tostring(details.command)
      end
    end
  end

  -- Fall back to parsing tool_input JSON
  if not tool_input then return "" end
  local input = json.decode(tool_input) as {string: any}
  if not input then return "" end

  if tool_name == "read" then
    local key = shorten_path(tostring(input.path or ""))
    local offset = tonumber(input.offset) as integer
    local limit = tonumber(input.limit) as integer
    if offset and offset > 0 and limit and limit > 0 then
      key = key .. ":" .. tostring(offset) .. "+" .. tostring(limit)
    elseif offset and offset > 0 then
      key = key .. ":" .. tostring(offset)
    elseif limit and limit > 0 then
      key = key .. " +" .. tostring(limit)
    end
    return key
  elseif tool_name == "write" or tool_name == "edit" then
    return shorten_path(tostring(input.path or ""))
  elseif tool_name == "bash" then
    return tostring(input.command or "")
  elseif tool_name == "result" then
    local offset = tonumber(input.offset) as integer
    local limit = tonumber(input.limit) as integer
    -- Mirror result.tl logic: header only emitted when NOT (offset<=1 AND limit==0)
    local eff_offset = (offset and offset > 0) and offset or 1
    local eff_limit = (limit and limit > 0) and limit or 0
    if eff_offset <= 1 and eff_limit == 0 then
      return ""
    end
    if eff_limit > 0 then
      local end_line = eff_offset + eff_limit - 1
      return string.format("[lines %d-%d]", eff_offset, end_line)
    else
      return string.format("[lines %d-]", eff_offset)
    end
  end
  return ""
end

-- Normalize a potentially multi-line command for display.
-- If the command has multiple lines, returns the first line with " ..." appended.
-- Also truncates at " \<newline>" continuations.
-- Single-line commands are returned unchanged.
local function display_command(cmd: string): string
  if not cmd or cmd == "" then return cmd end
  -- Handle \ continuations: " \<newline>" or " \<newline><whitespace>"
  local first_cont = cmd:match("^(.-) \\%s*\n")
  if first_cont then
    return first_cont .. " ..."
  end
  -- Handle newlines
  local first_nl = cmd:match("^([^\n]+)\n")
  if first_nl then
    return first_nl .. " ..."
  end
  return cmd
end

-- Wrap a single command segment (no && chains) at flag/space boundaries.
-- Returns cmd unchanged if it fits within width.
local function wrap_segment(cmd: string, width: integer, indent: string): string
  if #cmd <= width and not cmd:find(" #") then
    return cmd
  end

  -- Try splitting at comment/flag boundaries
  local parts: {string} = {}
  local current = ""
  for token in cmd:gmatch("%S+") do
    local is_comment = token:sub(1, 1) == "#" and current ~= ""
    local is_flag = current ~= "" and token:sub(1, 1) == "-" and #current + 1 + #token > width
    if is_comment or is_flag then
      table.insert(parts, current)
      current = indent .. token
    elseif current == "" then
      current = token
    else
      local candidate = current .. " " .. token
      if #candidate > width then
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

-- Wrap a long command at && boundaries and flag boundaries with \ continuations.
-- Normalizes multi-line commands to a single display line first.
-- Always breaks && chains onto separate indented lines.
-- Within each segment, wraps at flag/space boundaries if it exceeds width.
local function wrap_command(cmd: string, width: integer, indent: string): string
  width = width or 80
  indent = indent or "    "
  -- Normalize multi-line commands before any length checks or tokenization
  cmd = display_command(cmd)

  -- Split on && chains: always break these onto separate lines
  if cmd:find(" && ") then
    local segments: {string} = {}
    local rest = cmd
    while true do
      local pos = rest:find(" && ", 1, true)
      if not pos then
        table.insert(segments, rest)
        break
      end
      table.insert(segments, rest:sub(1, pos - 1))
      rest = rest:sub(pos + 4)
    end
    -- Wrap each segment individually, indent continuations
    local lines: {string} = {}
    for i, seg in ipairs(segments) do
      local trimmed = seg:match("^%s*(.-)%s*$") or seg
      if i == 1 then
        table.insert(lines, wrap_segment(trimmed, width, indent))
      else
        table.insert(lines, indent .. wrap_segment(trimmed, width - #indent, indent))
      end
    end
    return table.concat(lines, " && \\\n")
  end

  return wrap_segment(cmd, width, indent)
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

-- Repair message list: add synthetic tool_results for dangling tool_use,
-- and remove orphaned tool_results with no matching tool_use.
local function repair_dangling_tool_use(api_messages: {any}, on_event: events.EventCallback)
  -- Pass 1: add synthetic tool_results for assistant tool_use without following user tool_results.
  for i = #api_messages, 1, -1 do
    local msg = api_messages[i] as {string: any}
    if msg.role == "assistant" then
      local tool_use_ids: {string} = {}
      local msg_content = msg.content as {any}
      for _, block in ipairs(msg_content) do
        local b = block as {string: any}
        if b.type == "tool_use" then
          table.insert(tool_use_ids, b.id as string)
        end
      end

      if #tool_use_ids > 0 then
        local next_msg = api_messages[i + 1] as {string: any}
        local has_tool_results = false
        if next_msg ~= nil and next_msg.role == "user" then
          local next_content = next_msg.content as {any}
          for _, block in ipairs(next_content) do
            local b = block as {string: any}
            if b.type == "tool_result" then
              has_tool_results = true
              break
            end
          end
        end

        if not has_tool_results then
          local synthetic_results: {any} = {}
          for _, tid in ipairs(tool_use_ids) do
            table.insert(synthetic_results, {type = "tool_result", tool_use_id = tid, content = "error: tool execution was interrupted (session resumed)", is_error = true})
          end
          table.insert(api_messages, i + 1, {role = "user", content = synthetic_results})
          emit(on_event, events.error_event(string.format("repaired %d dangling tool_use block(s) in message history", #tool_use_ids)))
        end
      end
    end
  end

  -- Pass 2: remove orphaned tool_result blocks (user tool_result with no preceding assistant tool_use).
  local i = 1
  while i <= #api_messages do
    local msg = api_messages[i] as {string: any}
    if msg.role == "user" then
      -- Collect tool_use ids from the preceding assistant message.
      local valid_ids: {string: boolean} = {}
      if i > 1 then
        local prev = api_messages[i - 1] as {string: any}
        if prev.role == "assistant" then
          local prev_content = prev.content as {any}
          for _, block in ipairs(prev_content) do
            local b = block as {string: any}
            if b.type == "tool_use" then
              valid_ids[b.id as string] = true
            end
          end
        end
      end

      -- Filter out orphaned tool_result blocks.
      local content = msg.content as {any}
      local filtered: {any} = {}
      local removed = 0
      for _, block in ipairs(content) do
        local b = block as {string: any}
        if b.type == "tool_result" and not valid_ids[b.tool_use_id as string] then
          removed = removed + 1
        else
          table.insert(filtered, block)
        end
      end

      if removed > 0 then
        emit(on_event, events.error_event(string.format("removed %d orphaned tool_result block(s) from message history", removed)))
        if #filtered == 0 then
          table.remove(api_messages, i)
          goto continue_pass2
        else
          msg.content = filtered
        end
      end
    end
    i = i + 1
    ::continue_pass2::
  end
end

return {
  shorten_path = shorten_path,
  tool_key_param = tool_key_param,
  display_command = display_command,
  wrap_command = wrap_command,
  turn_signature = turn_signature,
  check_loop = check_loop,
  repair_dangling_tool_use = repair_dangling_tool_use,
}
