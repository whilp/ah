-- ah/tools.tl: tool loading, dispatch, initialization, and prompt generation
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local child = require("cosmic.child")
local signal = require("cosmic.signal")
local time = require("cosmic.time")
local util = require("ah.util")

local record ToolDetails
  path: string
  line_count: integer
  bytes: integer
  old_lines: integer
  new_lines: integer
  command: string
  exit_code: integer
  duration_ms: integer
  media_type: string
  skill_name: string
end

local record ToolContext
  db: any -- db.DB; typed as any to avoid circular dependency
end

local record Tool
  name: string
  description: string
  input_schema: {string: any}
  system_prompt: string
  running_processes: {integer: any}
  autoload: boolean -- false = only loaded via load_tool, not by default
  execute: function(input: {string: any}, context?: ToolContext): string, boolean, ToolDetails
end

-- Validate that a loaded module is a valid tool
local function is_valid_tool(t: any): boolean
  if type(t) ~= "table" then return false end
  local tool = t as {string: any}
  if type(tool.name) ~= "string" then return false end
  if type(tool.description) ~= "string" then return false end
  if type(tool.input_schema) ~= "table" then return false end
  if type(tool.execute) ~= "function" then return false end
  return true
end

-- Add a directory to package.path if not already present.
-- The teal package searcher substitutes .lua with .tl, so dir/?.lua covers both.
local function add_to_package_path(dir: string)
  local pattern = dir .. "/?.lua"
  if not package.path:find(pattern, 1, true) then
    package.path = pattern .. ";" .. dir .. "/?/init.lua;" .. package.path
  end
end

-- Track whether the teal package searcher has been installed.
local tl_searcher_installed = false

-- Ensure the tl package searcher is installed before any tl.load() usage.
local function ensure_tl_searcher(): {string: any}
  local tl = require("tl") as {string: any}
  if not tl_searcher_installed then
    local tl_loader = tl.loader as function()
    tl_loader()
    tl_searcher_installed = true
  end
  return tl
end

-- Check whether source code looks like a tool module using lightweight pattern
-- matching. Guards against loading files that aren't tool definitions.
-- Checks for table key assignments (name = ..., execute = ...) and a trailing
-- brace. Conservative: returns true for ambiguous cases (variable returns,
-- function calls, return nil) rather than rejecting valid tools.
local function looks_like_tool(source: string, _is_lua: boolean): boolean
  if #source == 0 then return false end
  -- reject scripts with no return statement
  if not source:find('return') then return false end
  -- strip trailing whitespace
  local trimmed = source:gsub("%s+$", "")
  -- if it ends with a table brace, check for required key assignments
  if trimmed:match("}%s*$") then
    -- look for key = value patterns (table field assignments)
    local name_pat = '[%s,{]name%s*='
    local has_name = source:find(name_pat) ~= nil or source:find('^name%s*=') ~= nil
    local exec_pat = '[%s,{]execute%s*='
    local has_execute = source:find(exec_pat) ~= nil or source:find('^execute%s*=') ~= nil
    return has_name and has_execute
  end
  -- non-table returns (variable, function call, nil): accept optimistically
  return true
end

-- Load a tool module from a .tl or .lua file.
local function load_tool_file(tool_path: string): any, string
  if tool_path:match("%.tl$") then
    local content = cio.slurp(tool_path)
    if not content then
      return nil, "failed to read file"
    end
    local tl = ensure_tl_searcher()
    local loader = tl.load as function(string): any, string
    return loader(content)
  end
  local loader = loadfile as function(string): any, string
  return loader(tool_path)
end

-- Load, execute, and validate a single tool file.
-- Returns the Tool on success, or nil and an error message.
local function load_single_tool(tool_path: string): Tool, string
  local load_ok, chunk, load_err = pcall(load_tool_file, tool_path)
  if not load_ok then
    return nil, string.format("failed to load %s: %s", tool_path, tostring(chunk))
  end
  if not chunk then
    return nil, string.format("failed to load %s: %s", tool_path, tostring(load_err))
  end
  local ok, result = pcall(chunk as function(): any)
  if not ok then
    return nil, string.format("failed to execute %s: %s", tool_path, tostring(result))
  end
  if not is_valid_tool(result) then
    return nil, string.format("invalid tool format in %s", tool_path)
  end
  return result as Tool, nil
end

-- Load lua/teal module tools from a directory.
-- .tl files take precedence over .lua files with the same basename.
local function load_custom_tools_from_dir(dir: string): {Tool}
  local loaded: {Tool} = {}

  local dh = fs.opendir(dir)
  if not dh then return loaded end
  local candidates: {string: string} = {}
  while true do
    local name = dh:read()
    if not name then break end

    if name:match("%.tl$") and not name:match("%.d%.tl$") then
      local base = name:sub(1, -4)
      candidates[base] = fs.join(dir, name)
    elseif name:match("%.lua$") then
      local base = name:sub(1, -5)
      if not candidates[base] or not (candidates[base]):match("%.tl$") then
        candidates[base] = fs.join(dir, name)
      end
    end
  end
  dh:close()
  local has_candidates = false
  for _ in pairs(candidates) do has_candidates = true; break end
  if has_candidates then
    add_to_package_path(dir)
  end

  for _, tool_path in pairs(candidates) do
    local source = cio.slurp(tool_path)
    if not source then
      util.debug(string.format("warning: failed to read %s", tool_path))
    elseif not looks_like_tool(source, tool_path:match("%.lua$") ~= nil) then
      util.debug(string.format("warning: skipping %s: does not look like a tool module", tool_path))
    else
      local tool, err = load_single_tool(tool_path)
      if tool then
        table.insert(loaded, tool)
      else
        util.debug(string.format("warning: %s", err))
      end
    end
  end

  return loaded
end

-- All tools loaded at runtime (system + embed + project)
local tools: {Tool} = {}

-- Merge tools into a name-indexed map (later calls override earlier)
local function merge_tools(by_name: {string: Tool}, new_tools: {Tool})
  for _, tool in ipairs(new_tools) do by_name[tool.name] = tool end
end

-- Initialize tools from standard locations.
-- Later sources override earlier ones by name:
--   1. system (/zip/embed/sys/tools, fallback sys/tools for dev)
--   2. embed  (/zip/embed/tools)
--   3. project (cwd/tools/ — both .lua modules and executables)
local function init_custom_tools(cwd?: string)
  cwd = cwd or fs.getcwd()
  local by_name: {string: Tool} = {}
  local sys_tools = load_custom_tools_from_dir("/zip/embed/sys/tools")
  if #sys_tools == 0 then sys_tools = load_custom_tools_from_dir("o/sys/tools") end
  merge_tools(by_name, sys_tools)
  merge_tools(by_name, load_custom_tools_from_dir("/zip/embed/tools"))
  local dot_ah_tools = fs.join(cwd, ".ah", "tools")
  local bare_tools = fs.join(cwd, "tools")
  local dh_check = fs.opendir(dot_ah_tools)
  local project_tools_dir: string
  if dh_check then
    dh_check:close()
    project_tools_dir = dot_ah_tools
  else
    project_tools_dir = bare_tools
  end
  merge_tools(by_name, load_custom_tools_from_dir(project_tools_dir))
  tools = {}
  for _, tool in pairs(by_name) do
    if tool.autoload ~= false then table.insert(tools, tool) end
  end
end

-- Load tools from a skill's tools/ subdirectory and merge into the active set.
local function load_skill_tools(base_dir: string)
  local tools_dir = base_dir .. "/tools"
  local dh = fs.opendir(tools_dir)
  if not dh then return end
  dh:close()
  add_to_package_path((fs.getcwd()))
  local by_name: {string: Tool} = {}
  for _, tool in ipairs(tools) do by_name[tool.name] = tool end
  merge_tools(by_name, load_custom_tools_from_dir(tools_dir))
  tools = {}
  for _, tool in pairs(by_name) do table.insert(tools, tool) end
end

-- Add a tool override by name (highest precedence).
-- cmd must end in .tl or .lua.
local function add_tool_override(name: string, cmd: string)
  if not (cmd:match("%.tl$") or cmd:match("%.lua$")) then
    util.debug(string.format("warning: tool %s: only .tl and .lua files are supported (got %s)", name, cmd))
    return
  end

  local dir = cmd:match("^(.+)/[^/]+$") or "."
  add_to_package_path(dir)

  local source = cio.slurp(cmd)
  if not source then
    util.debug(string.format("warning: failed to read tool %s from %s", name, cmd))
    return
  end
  if not looks_like_tool(source, cmd:match("%.lua$") ~= nil) then
    util.debug(string.format("warning: skipping tool %s from %s: does not look like a tool module", name, cmd))
    return
  end

  local tool, err = load_single_tool(cmd)
  if not tool then
    util.debug(string.format("warning: %s", err))
    return
  end
  tool.name = name

  for i, existing in ipairs(tools) do
    if existing.name == name then
      tools[i] = tool
      return
    end
  end
  table.insert(tools, tool)
end

-- Remove a tool by name. Returns true if found and removed.
local function remove_tool(name: string): boolean
  for i, tool in ipairs(tools) do
    if tool.name == name then
      table.remove(tools, i)
      return true
    end
  end
  return false
end
-- Load a tool from a file and add to the active set.
local function load_tool(tool_path: string): boolean, string
  local tool, err = load_single_tool(tool_path)
  if not tool then return false, err end
  for i, t in ipairs(tools) do
    if t.name == tool.name then
      tools[i] = tool
      return true, nil
    end
  end
  table.insert(tools, tool)
  return true, nil
end
local function get_all_tools(): {Tool}
  return tools
end

local function get_tool(name: string): Tool
  for _, tool in ipairs(tools) do
    if tool.name == name then
      return tool
    end
  end
  return nil
end

local function get_tool_definitions(): {{string: any}}
  local defs: {{string: any}} = {}
  for _, tool in ipairs(tools) do
    table.insert(defs, {
        name = tool.name,
        description = tool.description,
        input_schema = tool.input_schema,
      })
  end
  return defs
end

-- Format tool guidance for inclusion in the system prompt.
local function format_tools_for_prompt(): string
  local all = get_all_tools()
  if #all == 0 then return "" end

  local sorted: {Tool} = {}
  for _, t in ipairs(all) do table.insert(sorted, t) end
  table.sort(sorted, function(a: Tool, b: Tool): boolean
      return a.name < b.name
    end)

  local names: {string} = {}
  for _, tool in ipairs(sorted) do
    table.insert(names, tool.name)
  end

  local parts: {string} = {}
  table.insert(parts, "Tools: " .. table.concat(names, ", ") .. ".")

  for _, tool in ipairs(sorted) do
    table.insert(parts, tool.name .. ": " .. tool.description)
  end

  for _, tool in ipairs(sorted) do
    if tool.system_prompt and tool.system_prompt ~= "" then
      table.insert(parts, "")
      table.insert(parts, "## " .. tool.name)
      table.insert(parts, tool.system_prompt)
    end
  end

  return table.concat(parts, "\n")
end

-- Validate tool input against its JSON schema.
-- Returns nil on success, or an error string describing all validation failures.
local function validate_input(schema: {string: any}, input: {string: any}): string
  local errors: {string} = {}

  local required = schema.required as {string}
  if required then
    for _, prop in ipairs(required) do
      if input[prop] == nil then
        table.insert(errors, "missing required property: " .. prop)
      end
    end
  end

  local properties = schema.properties as {string: {string: any}}
  if properties then
    for prop, prop_schema in pairs(properties) do
      local value = input[prop]
      if value ~= nil then
        local expected_type = prop_schema.type as string
        if expected_type then
          local actual_type = type(value)
          local ok = false
          if expected_type == "string" then
            ok = actual_type == "string"
          elseif expected_type == "integer" or expected_type == "number" then
            ok = actual_type == "number"
          elseif expected_type == "boolean" then
            ok = actual_type == "boolean"
          elseif expected_type == "array" then
            ok = actual_type == "table"
          elseif expected_type == "object" then
            ok = actual_type == "table"
          end
          if not ok then
            table.insert(errors, string.format("property '%s': expected %s, got %s", prop, expected_type, actual_type))
          end
        end
      end
    end
  end

  if #errors > 0 then
    return "validation error: " .. table.concat(errors, "; ")
  end
  return nil
end

-- Abort all running tool processes with disciplined cleanup:
-- 1. Send SIGTERM, 2. Wait up to 2 seconds, 3. SIGKILL survivors
local function abort_running_tools()
  local running_processes: {integer: any} = {}
  for _, tool in ipairs(tools) do
    if tool.running_processes then
      for pid, handle in pairs(tool.running_processes) do
        running_processes[pid] = handle
      end
    end
  end

  local pids: {integer} = {}
  for pid, _ in pairs(running_processes) do
    table.insert(pids, pid)
  end
  if #pids == 0 then return end

  for _, pid in ipairs(pids) do
    pcall(function() signal.kill(pid, child.SIGTERM) end)
  end

  local deadline_s, deadline_ns = time.monotonic()
  deadline_s = deadline_s + 2
  while true do
    local still_running = false
    for _, pid in ipairs(pids) do
      if running_processes[pid] then
        local wpid, _ = child.wait(pid, child.WNOHANG)
        if wpid and wpid > 0 then
          running_processes[pid] = nil
        else
          still_running = true
        end
      end
    end

    if not still_running then break end
    local now_s, now_ns = time.monotonic()
    if now_s > deadline_s or (now_s == deadline_s and now_ns >= deadline_ns) then break end
    time.sleep(0, 50000000)
  end

  for _, pid in ipairs(pids) do
    if running_processes[pid] then
      pcall(function() signal.kill(pid, child.SIGKILL) end)
      pcall(function() child.wait(pid, 0) end)
      running_processes[pid] = nil
    end
  end
end

-- Coerce string values to integers where schema expects integer.
-- Claude models sometimes serialize integers as strings in JSON tool calls.
local function coerce_integer_params(schema: {string: any}, input: {string: any})
  local properties = schema.properties as {string: {string: any}}
  if not properties then return end

  for prop, prop_schema in pairs(properties) do
    local expected_type = prop_schema.type as string
    if expected_type == "integer" or expected_type == "number" then
      local value = input[prop]
      if type(value) == "string" then
        local num = tonumber(value)
        if num then
          input[prop] = num
        end
      end
    end
  end
end

local function execute_tool(name: string, input: {string: any}, context?: ToolContext): string, boolean, ToolDetails
  local tool = get_tool(name)
  if not tool then
    return "error: unknown tool: " .. name, true, nil
  end

  coerce_integer_params(tool.input_schema, input or {})

  local validation_err = validate_input(tool.input_schema, input or {})
  if validation_err then
    return validation_err, true, nil
  end

  return tool.execute(input, context)
end

return {
  get_tool_definitions = get_tool_definitions,
  format_tools_for_prompt = format_tools_for_prompt,
  execute_tool = execute_tool,
  abort_running_tools = abort_running_tools,
  validate_input = validate_input,
  init_custom_tools = init_custom_tools,
  load_skill_tools = load_skill_tools,
  add_tool_override = add_tool_override,
  remove_tool = remove_tool,
  load_tool = load_tool,
  load_custom_tools_from_dir = load_custom_tools_from_dir,
  is_valid_tool = is_valid_tool,
  looks_like_tool = looks_like_tool,
  Tool = Tool,
  ToolContext = ToolContext,
  ToolDetails = ToolDetails,
}
