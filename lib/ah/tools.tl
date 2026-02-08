-- ah/tools.tl: agent tools (read, write, edit, bash)
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local child = require("cosmic.child")
local cosmo = require("cosmo")
local json = require("cosmic.json")

-- Image extension to media type mapping
local IMAGE_TYPES: {string:string} = {
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  png = "image/png",
  gif = "image/gif",
  webp = "image/webp",
}

-- Tool name mapping for Claude Code compatibility (OAuth mode)
local CLAUDE_CODE_TOOLS: {string:string} = {
  read = "Read",
  write = "Write",
  edit = "Edit",
  bash = "Bash",
}

-- Reverse mapping for inbound tool calls
local CLAUDE_CODE_TOOLS_REVERSE: {string:string} = {
  Read = "read",
  Write = "write",
  Edit = "edit",
  Bash = "bash",
}

local function to_claude_code_name(name: string): string
  return CLAUDE_CODE_TOOLS[name] or name
end

local function from_claude_code_name(name: string): string
  return CLAUDE_CODE_TOOLS_REVERSE[name] or name
end

local record Tool
  name: string
  description: string
  input_schema: {string:any}
  execute: function(input: {string:any}): string, boolean
end

-- Custom tools loaded at runtime
local custom_tools: {Tool} = {}
local cli_tools: {Tool} = {}

-- Read file tool
local read_tool: Tool = {
  name = "read",
  description = "Read contents of a file (supports text and images: jpg, png, gif, webp)",
  input_schema = {
    type = "object",
    properties = {
      path = {type = "string", description = "Path to file to read"},
      offset = {type = "integer", description = "Line number to start reading from (1-indexed, text only)"},
      limit = {type = "integer", description = "Maximum number of lines to read (text only)"},
    },
    required = {"path"},
  },
  execute = function(input: {string:any}): string, boolean
    local file_path = input.path as string
    if not file_path then
      return "error: path is required", true
    end

    -- Check for image extension
    local ext = file_path:match("%.([^%.]+)$")
    if ext then
      ext = ext:lower()
    end
    local media_type = ext and IMAGE_TYPES[ext]

    if media_type then
      -- Read image file and return structured content
      local content = cio.slurp(file_path)
      if not content then
        return "error: failed to read file: " .. file_path, true
      end

      local base64_data = cosmo.EncodeBase64(content)
      local image_block = {
        __image__ = true,
        content = {{
          type = "image",
          source = {
            type = "base64",
            media_type = media_type,
            data = base64_data,
          },
        }},
      }
      return json.encode(image_block), false
    end

    -- Text file handling
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

    -- Perform replacement (escape % in replacement string)
    local escaped_new = new_string:gsub("%%", "%%%%")
    local new_content = content:gsub(old_string:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1"), escaped_new, 1)

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

    -- Timeout in milliseconds, default 120000 (2 minutes)
    local timeout_ms = (input.timeout as integer) or 120000
    local timeout_sec = math.ceil(timeout_ms / 1000)

    -- Wrap command with timeout
    local wrapped = string.format("timeout %d sh -c %q", timeout_sec, command)

    local handle, err = child.spawn({"sh", "-c", wrapped})
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

    -- Check for timeout (exit code 124)
    if exit_code == 124 then
      table.insert(result_parts, "error: command timed out after " .. timeout_sec .. "s")
    elseif exit_code ~= 0 then
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

-- Check if a file is executable
local function is_executable(path: string): boolean
  local handle, err = child.spawn({"test", "-x", path})
  if not handle then return false end
  local _, _, exit_str = handle:read()
  return tonumber(exit_str) == 0
end

-- Load CLI tools from a bin directory
-- Each executable becomes a tool; description from <name>.md or --help
local function load_cli_tools_from_dir(dir: string): {Tool}
  local loaded: {Tool} = {}

  local dh = fs.opendir(dir)
  if not dh then return loaded end

  while true do
    local name = dh:read()
    if not name then break end
    if name == "." or name == ".." then goto continue end

    local bin_path = fs.join(dir, name)

    -- Skip non-executables and .md files
    if name:match("%.md$") then goto continue end
    if not is_executable(bin_path) then goto continue end

    -- Get description from <name>.md or --help
    local description = "CLI tool: " .. name
    local md_path = fs.join(dir, name .. ".md")
    local md_content = cio.slurp(md_path)
    if md_content then
      -- Use first non-empty line as description
      for line in md_content:gmatch("[^\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed and trimmed ~= "" and not trimmed:match("^#") then
          description = trimmed
          break
        end
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
      input_schema = {
        type = "object",
        properties = {
          args = {type = "string", description = "Command-line arguments"},
        },
      },
      execute = function(input: {string:any}): string, boolean
        local args_str = (input.args as string) or ""

        -- Parse args string into array (simple space-split, respects quotes)
        local cmd = {tool_path}
        for arg in args_str:gmatch("%S+") do
          table.insert(cmd, arg)
        end

        local handle, err = child.spawn(cmd)
        if not handle then
          return "error: failed to spawn: " .. tostring(err), true
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

        return result, exit_code ~= 0
      end,
    }

    table.insert(loaded, tool)
    ::continue::
  end

  dh:close()
  return loaded
end

-- Merge CLI tools from global and project directories
local function load_cli_tools(global_dir: string, project_dir: string): {Tool}
  local by_name: {string:Tool} = {}

  if global_dir then
    local global_tools = load_cli_tools_from_dir(global_dir)
    for _, tool in ipairs(global_tools) do
      by_name[tool.name] = tool
    end
  end

  if project_dir then
    local project_tools = load_cli_tools_from_dir(project_dir)
    for _, tool in ipairs(project_tools) do
      by_name[tool.name] = tool
    end
  end

  local result: {Tool} = {}
  for _, tool in pairs(by_name) do
    table.insert(result, tool)
  end
  return result
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
  local cwd = fs.getcwd()

  -- Load Lua module tools: embedded sys -> global -> project (later overrides earlier)
  local sys_tools = load_custom_tools_from_dir("/zip/embed/sys/tools")
  local global_tools_dir = fs.join(home, ".ah", "tools")
  local project_tools_dir = fs.join(cwd, ".ah", "tools")
  local user_tools = load_custom_tools(global_tools_dir, project_tools_dir)

  -- Merge: user tools override sys tools
  custom_tools = sys_tools
  for _, tool in ipairs(user_tools) do
    local found = false
    for i, existing in ipairs(custom_tools) do
      if existing.name == tool.name then
        custom_tools[i] = tool
        found = true
        break
      end
    end
    if not found then
      table.insert(custom_tools, tool)
    end
  end

  -- Load CLI tools from .ah/bin/
  local global_bin_dir = fs.join(home, ".ah", "bin")
  local project_bin_dir = fs.join(cwd, ".ah", "bin")
  cli_tools = load_cli_tools(global_bin_dir, project_bin_dir)
end

-- Get all tools (builtin + custom)
-- Helper to add/override tool in list by name
local function add_or_override(all: {Tool}, tool: Tool)
  for i, existing in ipairs(all) do
    if existing.name == tool.name then
      all[i] = tool
      return
    end
  end
  table.insert(all, tool)
end

local function get_all_tools(): {Tool}
  local all: {Tool} = {}
  for _, tool in ipairs(builtin_tools) do
    table.insert(all, tool)
  end
  -- Custom Lua tools can override builtin
  for _, tool in ipairs(custom_tools) do
    add_or_override(all, tool)
  end
  -- CLI tools can override builtin and custom
  for _, tool in ipairs(cli_tools) do
    add_or_override(all, tool)
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

local function get_tool_definitions(is_oauth: boolean): {{string:any}}
  local defs: {{string:any}} = {}
  local all = get_all_tools()
  for _, tool in ipairs(all) do
    local name = tool.name
    if is_oauth then
      name = to_claude_code_name(name)
    end
    table.insert(defs, {
      name = name,
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
  load_cli_tools = load_cli_tools,
  load_cli_tools_from_dir = load_cli_tools_from_dir,
  is_valid_tool = is_valid_tool,
  to_claude_code_name = to_claude_code_name,
  from_claude_code_name = from_claude_code_name,
  Tool = Tool,
}
