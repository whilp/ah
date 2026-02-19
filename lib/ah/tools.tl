-- ah/tools.tl: tool loading, dispatch, and prompt generation
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local child = require("cosmic.child")
local signal = require("cosmic.signal")
local time = require("cosmic.time")

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
  input_schema: {string:any}
  system_prompt: string
  running_processes: {integer: any}
  execute: function(input: {string:any}): string, boolean, ToolDetails
end

-- All tools loaded at runtime (system + embed + project)
local tools: {Tool} = {}

-- Validate that a loaded module is a valid tool
local function is_valid_tool(t: any): boolean
  if type(t) ~= "table" then return false end
  local tool = t as {string:any}
  if type(tool.name) ~= "string" then return false end
  if type(tool.description) ~= "string" then return false end
  if type(tool.input_schema) ~= "table" then return false end
  if type(tool.execute) ~= "function" then return false end
  return true
end

-- Add a directory to package.path if not already present.
-- This enables require() for sibling .lua and .tl modules in the same directory.
-- The teal package searcher automatically substitutes .lua with .tl in package.path,
-- so adding dir/?.lua covers both lua and teal requires.
local function add_to_package_path(dir: string)
  local pattern = dir .. "/?.lua"
  if not package.path:find(pattern, 1, true) then
    package.path = pattern .. ";" .. dir .. "/?/init.lua;" .. package.path
  end
end

-- Track whether the teal package searcher has been installed.
-- tl.loader() registers a searcher in package.searchers so that
-- require() inside .tl files can find other .tl modules.
local tl_searcher_installed = false

-- Load a tool module from a .tl or .lua file.
-- Returns the loaded chunk or nil + error string.
local function load_tool_file(tool_path: string): any, string
  if tool_path:match("%.tl$") then
    local content = cio.slurp(tool_path)
    if not content then
      return nil, "failed to read file"
    end
    local tl = require("tl") as {string:any}
    if not tl_searcher_installed then
      local tl_loader = tl.loader as function()
      tl_loader()
      tl_searcher_installed = true
    end
    local loader = tl.load as function(string): any, string
    return loader(content)
  end
  local loader = loadfile as function(string): any, string
  return loader(tool_path)
end

-- Load lua/teal module tools from a directory.
-- .tl files take precedence over .lua files with the same basename.
local function load_custom_tools_from_dir(dir: string): {Tool}
  local loaded: {Tool} = {}

  local dh = fs.opendir(dir)
  if not dh then return loaded end

  -- Collect candidate files, .tl overrides .lua by basename
  local candidates: {string:string} = {}  -- basename -> path
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

  -- Add directory to package.path so tools can require sibling modules
  local has_candidates = false
  for _ in pairs(candidates) do has_candidates = true; break end
  if has_candidates then
    add_to_package_path(dir)
  end

  for _, tool_path in pairs(candidates) do
    local load_ok, chunk, load_err = pcall(load_tool_file, tool_path)
    if not load_ok then
      -- chunk holds the thrown error message when pcall catches a throw
      io.stderr:write(string.format("warning: failed to load %s: %s\n", tool_path, tostring(chunk)))
    elseif chunk then
      local ok, result = pcall(chunk as function(): any)
      if ok and is_valid_tool(result) then
        table.insert(loaded, result as Tool)
      elseif not ok then
        io.stderr:write(string.format("warning: failed to execute %s: %s\n", tool_path, tostring(result)))
      else
        io.stderr:write(string.format("warning: invalid tool format in %s\n", tool_path))
      end
    else
      io.stderr:write(string.format("warning: failed to load %s: %s\n", tool_path, tostring(load_err)))
    end
  end

  return loaded
end

-- Check if a file is executable
local function is_executable(path: string): boolean
  local handle, err = child.spawn({"test", "-x", path})
  if not handle then return false end
  local _, _, exit_str = handle:read()
  return tonumber(exit_str) == 0
end

-- Parse simple yaml frontmatter from markdown content.
-- Returns frontmatter fields and body (content after frontmatter).
local function parse_frontmatter(content: string): {string:string}, string
  local fields: {string:string} = {}

  if not content:match("^%-%-%-\n") then
    return fields, content
  end

  local fm_end = content:find("\n%-%-%-\n", 4)
  if not fm_end then
    return fields, content
  end

  local fm_block = content:sub(5, fm_end - 1)
  local body = content:sub(fm_end + 5)

  for line in fm_block:gmatch("[^\n]+") do
    local key, value = line:match("^([%w_%-]+):%s*(.+)$")
    if key and value then
      value = value:match("^[\"'](.+)[\"']$") or value
      fields[key] = value
    end
  end

  return fields, body
end

-- Load CLI tools from a directory.
-- Each executable becomes a tool; description and system_prompt from <name>.md
local function load_cli_tools_from_dir(dir: string): {Tool}
  local loaded: {Tool} = {}

  local dh = fs.opendir(dir)
  if not dh then return loaded end

  while true do
    local name = dh:read()
    if not name then break end
    if name == "." or name == ".." then goto continue end

    local bin_path = fs.join(dir, name)

    -- Skip non-executables and metadata/source files
    if name:match("%.md$") then goto continue end
    if name:match("%.lua$") then goto continue end
    if name:match("%.tl$") then goto continue end
    if not is_executable(bin_path) then goto continue end

    -- Get description and system_prompt from <name>.md (frontmatter + body)
    local description = "CLI tool: " .. name
    local tool_system_prompt: string = nil
    local md_path = fs.join(dir, name .. ".md")
    local md_content = cio.slurp(md_path)
    if md_content then
      local fields, body = parse_frontmatter(md_content)
      if fields.description and fields.description ~= "" then
        description = fields.description
      else
        -- Fall back to first non-empty, non-heading line
        for line in md_content:gmatch("[^\n]+") do
          local trimmed = line:match("^%s*(.-)%s*$")
          if trimmed and trimmed ~= "" and not trimmed:match("^#") then
            description = trimmed
            break
          end
        end
      end
      -- Body after frontmatter becomes system_prompt guidance
      local trimmed_body = body:match("^%s*(.-)%s*$")
      if trimmed_body and trimmed_body ~= "" then
        tool_system_prompt = trimmed_body
      end
    else
      -- Try --help
      local handle = child.spawn({bin_path, "--help"})
      if handle then
        local _, stdout = handle:read()
        if stdout and stdout ~= "" then
          local first_line = (stdout as string):match("^[^\n]+")
          if first_line then
            description = first_line:sub(1, 200)
          end
        end
      end
    end

    -- Create tool
    local tool_name = name
    local tool_path = bin_path
    local tool: Tool = {
      name = tool_name,
      description = description,
      system_prompt = tool_system_prompt,
      input_schema = {
        type = "object",
        properties = {
          args = {type = "string", description = "Command-line arguments"},
        },
      },
      execute = function(input: {string:any}): string, boolean, ToolDetails
        local args_str = (input.args as string) or ""

        -- Invoke via bash -c so args get proper shell expansion
        local shell_cmd = tool_path
        if args_str ~= "" then
          shell_cmd = shell_cmd .. " " .. args_str
        end

        local handle, err = child.spawn({os.getenv("AH_SHELL") or "bash", "-c", shell_cmd})
        if not handle then
          return "error: failed to spawn: " .. tostring(err), true, nil
        end

        local _, stdout, exit_str = handle:read()
        local stdout_str = (stdout as string) or ""
        local exit_code = tonumber(exit_str) as integer or 0

        local result_parts: {string} = {}
        if stdout_str ~= "" then
          table.insert(result_parts, stdout_str)
        end
        if exit_code ~= 0 then
          table.insert(result_parts, "exit code: " .. tostring(exit_code))
        end

        local result = table.concat(result_parts, "\n")
        if result == "" then
          result = "(no output)"
        end

        return result, exit_code ~= 0,
          {command = tool_name .. " " .. args_str, exit_code = exit_code} as ToolDetails
      end,
    }

    table.insert(loaded, tool)
    ::continue::
  end

  dh:close()
  return loaded
end

-- Merge tools into a name-indexed map (later calls override earlier)
local function merge_tools(by_name: {string:Tool}, new_tools: {Tool})
  for _, tool in ipairs(new_tools) do
    by_name[tool.name] = tool
  end
end

-- Initialize tools from standard locations.
-- Later sources override earlier ones by name:
--   1. system (/zip/embed/sys/tools, fallback sys/tools for dev)
--   2. embed  (/zip/embed/tools)
--   3. project (cwd/tools/ — both .lua modules and executables)
local function init_custom_tools(cwd?: string)
  cwd = cwd or fs.getcwd()

  local by_name: {string:Tool} = {}

  -- System tier: try embedded path first, fall back to compiled source for dev/test
  local sys_tools = load_custom_tools_from_dir("/zip/embed/sys/tools")
  if #sys_tools == 0 then
    sys_tools = load_custom_tools_from_dir("o/sys/tools")
  end
  merge_tools(by_name, sys_tools)

  -- Embed tier: lua modules
  merge_tools(by_name, load_custom_tools_from_dir("/zip/embed/tools"))

  -- Project tier: .ah/tools wins over tools/ if present
  -- Precedence within a directory: .tl > .lua > executable
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
  merge_tools(by_name, load_cli_tools_from_dir(project_tools_dir))
  merge_tools(by_name, load_custom_tools_from_dir(project_tools_dir))

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
  add_to_package_path((fs.getcwd()))

  -- Build name index of current tools
  local by_name: {string:Tool} = {}
  for _, tool in ipairs(tools) do
    by_name[tool.name] = tool
  end

  -- Load CLI tools (executables) then module tools (.tl/.lua)
  -- Module tools override CLI tools with the same basename
  merge_tools(by_name, load_cli_tools_from_dir(tools_dir))
  merge_tools(by_name, load_custom_tools_from_dir(tools_dir))

  tools = {}
  for _, tool in pairs(by_name) do
    table.insert(tools, tool)
  end
end

-- Add a tool override by name.
-- If cmd ends in .tl or .lua, loads it as a module tool.
-- Otherwise treats cmd as an executable path (wrapped as a CLI tool).
-- This has highest precedence — it overrides system, embed, and project tools.
local function add_tool_override(name: string, cmd: string)
  -- .tl / .lua files: load as module tools
  if cmd:match("%.tl$") or cmd:match("%.lua$") then
    -- Add tool's directory to package.path for sibling requires
    local dir = cmd:match("^(.+)/[^/]+$") or "."
    add_to_package_path(dir)

    local load_ok, chunk, load_err = pcall(load_tool_file, cmd)
    if not load_ok then
      -- chunk holds the thrown error message when pcall catches a throw
      io.stderr:write(string.format("warning: failed to load tool %s from %s: %s\n", name, cmd, tostring(chunk)))
      return
    end
    if not chunk then
      io.stderr:write(string.format("warning: failed to load tool %s from %s: %s\n", name, cmd, tostring(load_err)))
      return
    end
    local ok, result = pcall(chunk as function(): any)
    if not ok then
      io.stderr:write(string.format("warning: failed to execute tool %s from %s: %s\n", name, cmd, tostring(result)))
      return
    end
    if not is_valid_tool(result) then
      io.stderr:write(string.format("warning: invalid tool format in %s\n", cmd))
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
    return
  end

  -- Executable: wrap as CLI tool
  -- Read description/system_prompt from <cmd>.md if it exists
  local description = "CLI tool: " .. name
  local tool_system_prompt: string = nil
  local md_path = cmd .. ".md"
  local md_content = cio.slurp(md_path)
  if md_content then
    local fields, body = parse_frontmatter(md_content)
    if fields.description and fields.description ~= "" then
      description = fields.description
    end
    local trimmed_body = body:match("^%s*(.-)%s*$")
    if trimmed_body and trimmed_body ~= "" then
      tool_system_prompt = trimmed_body
    end
  end

  local tool_cmd = cmd
  local tool: Tool = {
    name = name,
    description = description,
    system_prompt = tool_system_prompt,
    input_schema = {
      type = "object",
      properties = {
        args = {type = "string", description = "Command-line arguments"},
      },
    },
    execute = function(input: {string:any}): string, boolean, ToolDetails
      local args_str = (input.args as string) or ""
      -- Invoke via bash -c so args get proper shell expansion
      local shell_cmd = tool_cmd
      if args_str ~= "" then
        shell_cmd = shell_cmd .. " " .. args_str
      end

      local handle, spawn_err = child.spawn({os.getenv("AH_SHELL") or "bash", "-c", shell_cmd})
      if not handle then
        return "error: failed to spawn: " .. tostring(spawn_err), true, nil
      end

      local _, stdout, exit_str = handle:read()
      local stdout_str = (stdout as string) or ""
      local exit_code = tonumber(exit_str) as integer or 0

      local result_parts: {string} = {}
      if stdout_str ~= "" then
        table.insert(result_parts, stdout_str)
      end
      if exit_code ~= 0 then
        table.insert(result_parts, "exit code: " .. tostring(exit_code))
      end

      local result = table.concat(result_parts, "\n")
      if result == "" then
        result = "(no output)"
      end

      return result, exit_code ~= 0,
        {command = name .. " " .. args_str, exit_code = exit_code} as ToolDetails
    end,
  }

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

local function get_tool_definitions(): {{string:any}}
  local defs: {{string:any}} = {}
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
local function validate_input(schema: {string:any}, input: {string:any}): string
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
  local properties = schema.properties as {string:{string:any}}
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
local function coerce_integer_params(schema: {string:any}, input: {string:any})
  local properties = schema.properties as {string:{string:any}}
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

local function execute_tool(name: string, input: {string:any}): string, boolean, ToolDetails
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
  load_custom_tools_from_dir = load_custom_tools_from_dir,
  load_cli_tools_from_dir = load_cli_tools_from_dir,
  is_valid_tool = is_valid_tool,
  Tool = Tool,
  ToolDetails = ToolDetails,
}
