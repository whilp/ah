-- ah/tools.tl: tool dispatch, initialization, and prompt generation
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local child = require("cosmic.child")
local signal = require("cosmic.signal")
local time = require("cosmic.time")
local toolload = require("ah.toolload")
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

local record Tool
  name: string
  description: string
  input_schema: {string: any}
  system_prompt: string
  running_processes: {integer: any}
  execute: function(input: {string: any}): string, boolean, ToolDetails
end

-- All tools loaded at runtime (system + embed + project)
local tools: {Tool} = {}

-- Merge tools into a name-indexed map (later calls override earlier)
local function merge_tools(by_name: {string: Tool}, new_tools: {toolload.Tool})
  for _, tool in ipairs(new_tools) do
    by_name[tool.name] = tool as Tool
  end
end

-- Initialize tools from standard locations.
-- Later sources override earlier ones by name:
--   1. system (/zip/embed/sys/tools, fallback sys/tools for dev)
--   2. embed  (/zip/embed/tools)
--   3. project (cwd/tools/ — both .lua modules and executables)
local function init_custom_tools(cwd?: string)
  cwd = cwd or fs.getcwd()

  local by_name: {string: Tool} = {}

  -- System tier: try embedded path first, fall back to compiled source for dev/test
  local sys_tools = toolload.load_custom_tools_from_dir("/zip/embed/sys/tools")
  if #sys_tools == 0 then
    sys_tools = toolload.load_custom_tools_from_dir("o/sys/tools")
  end
  merge_tools(by_name, sys_tools)

  -- Embed tier: lua modules
  merge_tools(by_name, toolload.load_custom_tools_from_dir("/zip/embed/tools"))

  -- Project tier: .ah/tools wins over tools/ if present
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
  merge_tools(by_name, toolload.load_custom_tools_from_dir(project_tools_dir))

  tools = {}
  for _, tool in pairs(by_name) do
    table.insert(tools, tool)
  end
end

-- Load tools from a skill's tools/ subdirectory and merge them into
-- the active tool set. Called when a skill is invoked (--skill, /skill:name,
-- or the skill tool at runtime). Skill tools override project-tier tools
-- by name but are overridden by --tool CLI overrides.
local function load_skill_tools(base_dir: string)
  local tools_dir = base_dir .. "/tools"
  local dh = fs.opendir(tools_dir)
  if not dh then return end
  dh:close()

  -- Ensure project root is in package.path so skill tools
  -- can require() shared modules (e.g. "lib.mcp")
  toolload.add_to_package_path((fs.getcwd()))

  -- Build name index of current tools
  local by_name: {string: Tool} = {}
  for _, tool in ipairs(tools) do
    by_name[tool.name] = tool
  end

  -- Load module tools (.tl/.lua)
  merge_tools(by_name, toolload.load_custom_tools_from_dir(tools_dir))

  tools = {}
  for _, tool in pairs(by_name) do
    table.insert(tools, tool)
  end
end

-- Add a tool override by name.
-- cmd must end in .tl or .lua — loads it as a module tool.
-- This has highest precedence — it overrides system, embed, and project tools.
local function add_tool_override(name: string, cmd: string)
  if not (cmd:match("%.tl$") or cmd:match("%.lua$")) then
    util.debug(string.format("warning: tool %s: only .tl and .lua files are supported (got %s)", name, cmd))
    return
  end

  -- Add tool's directory to package.path for sibling requires
  local dir = cmd:match("^(.+)/[^/]+$") or "."
  toolload.add_to_package_path(dir)

  -- Read source and check AST before evaluating — guards against os.exit()
  local source = cio.slurp(cmd)
  if not source then
    util.debug(string.format("warning: failed to read tool %s from %s", name, cmd))
    return
  end
  if not toolload.looks_like_tool(source, cmd:match("%.lua$") ~= nil) then
    util.debug(string.format("warning: skipping tool %s from %s: does not look like a tool module", name, cmd))
    return
  end

  local load_ok, chunk, load_err = pcall(toolload.load_tool_file, cmd)
  if not load_ok then
    util.debug(string.format("warning: failed to load tool %s from %s: %s", name, cmd, tostring(chunk)))
    return
  end
  if not chunk then
    util.debug(string.format("warning: failed to load tool %s from %s: %s", name, cmd, tostring(load_err)))
    return
  end
  local ok, result = pcall(chunk as function(): any)
  if not ok then
    util.debug(string.format("warning: failed to execute tool %s from %s: %s", name, cmd, tostring(result)))
    return
  end
  if not toolload.is_valid_tool(result) then
    util.debug(string.format("warning: invalid tool format in %s", cmd))
    return
  end
  local tool = result as Tool
  -- Use the name from --tool flag, not the module's internal name
  tool.name = name

  -- Override existing or append
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
-- Generates a "Tools:" summary line and appends any per-tool system_prompt bodies.
local function format_tools_for_prompt(): string
  local all = get_all_tools()
  if #all == 0 then return "" end

  -- Sorted tool names for deterministic output
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

  -- Brief description line for each tool
  for _, tool in ipairs(sorted) do
    table.insert(parts, tool.name .. ": " .. tool.description)
  end

  -- Append per-tool system_prompt guidance
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

  -- Check required properties
  local required = schema.required as {string}
  if required then
    for _, prop in ipairs(required) do
      if input[prop] == nil then
        table.insert(errors, "missing required property: " .. prop)
      end
    end
  end

  -- Check property types
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
-- 1. Send SIGTERM to all running processes
-- 2. Wait up to 2 seconds for graceful exit
-- 3. Send SIGKILL to any survivors
local function abort_running_tools()
  -- Find running_processes from the bash tool (or any tool that exposes it)
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

  if #pids == 0 then
    return
  end

  -- Phase 1: SIGTERM all running processes
  for _, pid in ipairs(pids) do
    pcall(function() signal.kill(pid, child.SIGTERM) end)
  end

  -- Phase 2: Wait up to 2 seconds for graceful exit
  local deadline_s, deadline_ns = time.monotonic()
  deadline_s = deadline_s + 2

  while true do
    -- Check if all processes have exited
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

    if not still_running then
      break
    end

    -- Check deadline
    local now_s, now_ns = time.monotonic()
    if now_s > deadline_s or (now_s == deadline_s and now_ns >= deadline_ns) then
      break
    end

    -- Brief sleep before rechecking (50ms)
    time.sleep(0, 50000000)
  end

  -- Phase 3: SIGKILL any survivors
  for _, pid in ipairs(pids) do
    if running_processes[pid] then
      pcall(function() signal.kill(pid, child.SIGKILL) end)
      pcall(function() child.wait(pid, 0) end)
      running_processes[pid] = nil
    end
  end
end

-- Coerce string values to integers where schema expects integer
-- Claude models sometimes serialize integers as strings in JSON tool calls
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

local function execute_tool(name: string, input: {string: any}): string, boolean, ToolDetails
  local tool = get_tool(name)
  if not tool then
    return "error: unknown tool: " .. name, true, nil
  end

  -- Coerce string integers to integers before validation
  -- Claude models sometimes serialize integers as strings
  coerce_integer_params(tool.input_schema, input or {})

  -- Validate input against schema before execution
  local validation_err = validate_input(tool.input_schema, input or {})
  if validation_err then
    return validation_err, true, nil
  end

  return tool.execute(input)
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
  load_custom_tools_from_dir = toolload.load_custom_tools_from_dir,
  is_valid_tool = toolload.is_valid_tool,
  looks_like_tool = toolload.looks_like_tool,
  Tool = Tool,
  ToolDetails = ToolDetails,
}
