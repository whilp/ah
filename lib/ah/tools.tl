-- ah/tools.tl: agent tools (read, write, edit, bash)
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local child = require("cosmic.child")

local record Tool
  name: string
  description: string
  input_schema: {string:any}
  execute: function(input: {string:any}): string, boolean
end

-- Custom tools loaded at runtime
local custom_tools: {Tool} = {}

-- Read file tool
local read_tool: Tool = {
  name = "read",
  description = "Read contents of a file",
  input_schema = {
    type = "object",
    properties = {
      path = {type = "string", description = "Path to file to read"},
      offset = {type = "integer", description = "Line number to start reading from (1-indexed)"},
      limit = {type = "integer", description = "Maximum number of lines to read"},
    },
    required = {"path"},
  },
  execute = function(input: {string:any}): string, boolean
    local file_path = input.path as string
    if not file_path then
      return "error: path is required", true
    end

    local content = cio.slurp(file_path)
    if not content then
      return "error: failed to read file: " .. file_path, true
    end

    local offset = (input.offset as integer) or 1
    local limit = (input.limit as integer) or 0

    if offset > 1 or limit > 0 then
      local lines: {string} = {}
      local line_num = 0
      for line in content:gmatch("[^\n]*") do
        line_num = line_num + 1
        if line_num >= offset then
          if limit > 0 and line_num >= offset + limit then
            break
          end
          table.insert(lines, string.format("%d\t%s", line_num, line))
        end
      end
      return table.concat(lines, "\n"), false
    end

    -- Add line numbers
    local lines: {string} = {}
    local line_num = 0
    for line in content:gmatch("[^\n]*") do
      line_num = line_num + 1
      table.insert(lines, string.format("%d\t%s", line_num, line))
    end
    return table.concat(lines, "\n"), false
  end,
}

-- Write file tool
local write_tool: Tool = {
  name = "write",
  description = "Write content to a file (creates or overwrites)",
  input_schema = {
    type = "object",
    properties = {
      path = {type = "string", description = "Path to file to write"},
      content = {type = "string", description = "Content to write"},
    },
    required = {"path", "content"},
  },
  execute = function(input: {string:any}): string, boolean
    local file_path = input.path as string
    local content = input.content as string

    if not file_path then
      return "error: path is required", true
    end
    if not content then
      return "error: content is required", true
    end

    -- Create parent directories if needed
    local dir = fs.dirname(file_path)
    if dir and dir ~= "" then
      fs.makedirs(dir)
    end

    local ok = cio.barf(file_path, content, tonumber("644", 8))
    if not ok then
      return "error: failed to write file: " .. file_path, true
    end

    return "wrote " .. tostring(#content) .. " bytes to " .. file_path, false
  end,
}

-- Edit file tool
local edit_tool: Tool = {
  name = "edit",
  description = "Replace text in a file (old_string must be unique)",
  input_schema = {
    type = "object",
    properties = {
      path = {type = "string", description = "Path to file to edit"},
      old_string = {type = "string", description = "Text to find and replace"},
      new_string = {type = "string", description = "Replacement text"},
    },
    required = {"path", "old_string", "new_string"},
  },
  execute = function(input: {string:any}): string, boolean
    local file_path = input.path as string
    local old_string = input.old_string as string
    local new_string = input.new_string as string

    if not file_path then
      return "error: path is required", true
    end
    if not old_string then
      return "error: old_string is required", true
    end
    if new_string == nil then
      return "error: new_string is required", true
    end

    local content = cio.slurp(file_path)
    if not content then
      return "error: failed to read file: " .. file_path, true
    end

    -- Check uniqueness
    local _, count = content:gsub(old_string:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1"), "")
    if count == 0 then
      return "error: old_string not found in file", true
    end
    if count > 1 then
      return "error: old_string is not unique (found " .. count .. " times)", true
    end

    -- Perform replacement
    local new_content = content:gsub(old_string:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1"), new_string, 1)

    local ok = cio.barf(file_path, new_content, tonumber("644", 8))
    if not ok then
      return "error: failed to write file: " .. file_path, true
    end

    return "edited " .. file_path, false
  end,
}

-- Bash tool
local bash_tool: Tool = {
  name = "bash",
  description = "Execute a bash command",
  input_schema = {
    type = "object",
    properties = {
      command = {type = "string", description = "Command to execute"},
      timeout = {type = "integer", description = "Timeout in milliseconds (default: 120000)"},
    },
    required = {"command"},
  },
  execute = function(input: {string:any}): string, boolean
    local command = input.command as string
    if not command then
      return "error: command is required", true
    end

    local handle, err = child.spawn({"sh", "-c", command})
    if not handle then
      return "error: failed to spawn: " .. tostring(err), true
    end

    -- Read output: h:read() returns (ok, stdout, exit_code_as_string)
    local ok, stdout, exit_str = handle:read()

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

    return result, exit_code ~= 0
  end,
}

local builtin_tools: {Tool} = {read_tool, write_tool, edit_tool, bash_tool}

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

-- Load custom tools from a directory
local function load_custom_tools_from_dir(dir: string): {Tool}
  local loaded: {Tool} = {}

  local dh = fs.opendir(dir)
  if not dh then return loaded end

  while true do
    local name = dh:read()
    if not name then break end

    if name:match("%.lua$") then
      local tool_path = fs.join(dir, name)
      local chunk, load_err = loadfile(tool_path)
      if chunk then
        local ok, result = pcall(chunk)
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
  end

  dh:close()
  return loaded
end

-- Merge tools from global and project directories (project overrides global by name)
local function load_custom_tools(global_dir: string, project_dir: string): {Tool}
  local by_name: {string:Tool} = {}

  -- Load global tools first
  if global_dir then
    local global_tools = load_custom_tools_from_dir(global_dir)
    for _, tool in ipairs(global_tools) do
      by_name[tool.name] = tool
    end
  end

  -- Load project tools (override global by name)
  if project_dir then
    local project_tools = load_custom_tools_from_dir(project_dir)
    for _, tool in ipairs(project_tools) do
      by_name[tool.name] = tool
    end
  end

  -- Convert to array
  local result: {Tool} = {}
  for _, tool in pairs(by_name) do
    table.insert(result, tool)
  end
  return result
end

-- Initialize custom tools from standard locations
local function init_custom_tools()
  local home = os.getenv("HOME") or ""
  local global_tools_dir = fs.join(home, ".ah", "tools")
  local cwd = fs.getcwd()
  local project_tools_dir = fs.join(cwd, ".ah", "tools")

  custom_tools = load_custom_tools(global_tools_dir, project_tools_dir)
end

-- Get all tools (builtin + custom)
local function get_all_tools(): {Tool}
  local all: {Tool} = {}
  for _, tool in ipairs(builtin_tools) do
    table.insert(all, tool)
  end
  for _, tool in ipairs(custom_tools) do
    -- Custom tools can override builtin tools by name
    local found = false
    for i, builtin in ipairs(all) do
      if builtin.name == tool.name then
        all[i] = tool
        found = true
        break
      end
    end
    if not found then
      table.insert(all, tool)
    end
  end
  return all
end

local function get_tool(name: string): Tool
  local all = get_all_tools()
  for _, tool in ipairs(all) do
    if tool.name == name then
      return tool
    end
  end
  return nil
end

local function get_tool_definitions(): {{string:any}}
  local defs: {{string:any}} = {}
  local all = get_all_tools()
  for _, tool in ipairs(all) do
    table.insert(defs, {
      name = tool.name,
      description = tool.description,
      input_schema = tool.input_schema,
    })
  end
  return defs
end

local function execute_tool(name: string, input: {string:any}): string, boolean
  local tool = get_tool(name)
  if not tool then
    return "error: unknown tool: " .. name, true
  end
  return tool.execute(input)
end

return {
  get_tool_definitions = get_tool_definitions,
  execute_tool = execute_tool,
  init_custom_tools = init_custom_tools,
  load_custom_tools = load_custom_tools,
  load_custom_tools_from_dir = load_custom_tools_from_dir,
  is_valid_tool = is_valid_tool,
  Tool = Tool,
}
