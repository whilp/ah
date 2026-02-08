-- ah/commands.tl: command loading and expansion
local fs = require("cosmic.fs")
local cio = require("cosmic.io")

-- Command record
local record Command
  name: string
  content: string
end

-- Parse args with bash-style quoting
-- Handles: simple words, "double quoted", 'single quoted', escaped chars
local function parse_args(s: string): {string}
  local args: {string} = {}
  local i = 1
  local len = #s

  while i <= len do
    -- skip whitespace
    while i <= len and s:sub(i, i):match("%s") do
      i = i + 1
    end
    if i > len then break end

    local c = s:sub(i, i)
    local arg = ""

    if c == '"' then
      -- double-quoted string
      i = i + 1
      while i <= len do
        c = s:sub(i, i)
        if c == '"' then
          i = i + 1
          break
        elseif c == "\\" and i + 1 <= len then
          -- escape next char
          i = i + 1
          arg = arg .. s:sub(i, i)
          i = i + 1
        else
          arg = arg .. c
          i = i + 1
        end
      end
      table.insert(args, arg)
    elseif c == "'" then
      -- single-quoted string (no escapes)
      i = i + 1
      while i <= len do
        c = s:sub(i, i)
        if c == "'" then
          i = i + 1
          break
        else
          arg = arg .. c
          i = i + 1
        end
      end
      table.insert(args, arg)
    else
      -- unquoted word
      while i <= len do
        c = s:sub(i, i)
        if c:match("%s") then
          break
        elseif c == "\\" and i + 1 <= len then
          i = i + 1
          arg = arg .. s:sub(i, i)
          i = i + 1
        else
          arg = arg .. c
          i = i + 1
        end
      end
      if #arg > 0 then
        table.insert(args, arg)
      end
    end
  end

  return args
end

-- Substitute args into content
-- Order: $1, $2, ... -> ${@:N:L} -> ${@:N} -> $@/$ARGUMENTS
local function substitute_args(content: string, args: {string}): string
  local result = content

  -- 1. Replace positional args $1, $2, ... (highest first to avoid $1 matching in $10)
  for i = #args, 1, -1 do
    result = result:gsub("%$" .. tostring(i), args[i] or "")
  end

  -- 2. Replace ${@:N:L} (slice from N with length L)
  result = result:gsub("%${@:(%d+):(%d+)}", function(start_str: string, len_str: string): string
    local start = tonumber(start_str) as integer
    local slice_len = tonumber(len_str) as integer
    local parts: {string} = {}
    for i = start, math.min(start + slice_len - 1, #args) do
      if args[i] then
        table.insert(parts, args[i])
      end
    end
    return table.concat(parts, " ")
  end)

  -- 3. Replace ${@:N} (slice from N to end)
  result = result:gsub("%${@:(%d+)}", function(start_str: string): string
    local start = tonumber(start_str) as integer
    local parts: {string} = {}
    for i = start, #args do
      if args[i] then
        table.insert(parts, args[i])
      end
    end
    return table.concat(parts, " ")
  end)

  -- 4. Replace $@ and $ARGUMENTS with all args joined
  local all_args = table.concat(args, " ")
  result = result:gsub("%$@", all_args)
  result = result:gsub("%$ARGUMENTS", all_args)

  return result
end

-- Load commands from a directory
local function load_commands_from_dir(dir: string): {Command}
  local commands: {Command} = {}

  local dh = fs.opendir(dir)
  if not dh then return commands end

  while true do
    local name = dh:read()
    if not name then break end

    if name:match("%.md$") then
      local cmd_path = fs.join(dir, name)
      local content = cio.slurp(cmd_path)
      if content then
        local cmd_name = name:gsub("%.md$", "")
        table.insert(commands, {
          name = cmd_name,
          content = content
        })
      end
    end
  end

  dh:close()
  return commands
end

-- Load all commands from system and user directories
-- User commands override system commands by name
local function load_commands(): {string:Command}
  local commands: {string:Command} = {}

  -- Load system commands first
  local sys_commands = load_commands_from_dir("/zip/embed/sys/commands")
  for _, cmd in ipairs(sys_commands) do
    commands[cmd.name] = cmd
  end

  -- Load user commands (override system)
  local user_commands = load_commands_from_dir("/zip/embed/commands")
  for _, cmd in ipairs(user_commands) do
    commands[cmd.name] = cmd
  end

  return commands
end

-- Expand a command if the prompt starts with /
-- Returns: expanded content, was_command flag
local function expand_command(prompt: string, commands: {string:Command}): string, boolean
  -- Check if prompt starts with /
  if not prompt:match("^/") then
    return prompt, false
  end

  -- Extract command name and args
  local cmd_name = prompt:match("^/([%w_%-]+)")
  if not cmd_name then
    return prompt, false
  end

  local cmd = commands[cmd_name]
  if not cmd then
    -- Unknown command, pass through unchanged
    return prompt, false
  end

  -- Extract args (everything after command name)
  local args_str = prompt:match("^/[%w_%-]+%s*(.*)")
  local args = parse_args(args_str or "")

  -- Substitute args into command content
  local expanded = substitute_args(cmd.content, args)

  return expanded, true
end

return {
  parse_args = parse_args,
  substitute_args = substitute_args,
  load_commands = load_commands,
  expand_command = expand_command,
}
