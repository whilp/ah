-- ah/tools.tl: agent tools (read, write, edit, bash)
local cosmo = require("cosmo")
local path = require("cosmo.path")
local unix = require("cosmo.unix")
local child = require("cosmic.child")

local record Tool
  name: string
  description: string
  input_schema: {string:any}
  execute: function(input: {string:any}): string, boolean
end

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

    local content = cosmo.Slurp(file_path)
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
    local dir = path.dirname(file_path)
    if dir and dir ~= "" then
      unix.makedirs(dir)
    end

    local ok = cosmo.Barf(file_path, content, tonumber("644", 8))
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

    local content = cosmo.Slurp(file_path)
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

    local ok = cosmo.Barf(file_path, new_content, tonumber("644", 8))
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

local all_tools: {Tool} = {read_tool, write_tool, edit_tool, bash_tool}

local function get_tool(name: string): Tool
  for _, tool in ipairs(all_tools) do
    if tool.name == name then
      return tool
    end
  end
  return nil
end

local function get_tool_definitions(): {{string:any}}
  local defs: {{string:any}} = {}
  for _, tool in ipairs(all_tools) do
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
  Tool = Tool,
  read_tool = read_tool,
  write_tool = write_tool,
  edit_tool = edit_tool,
  bash_tool = bash_tool,
  all_tools = all_tools,
  get_tool = get_tool,
  get_tool_definitions = get_tool_definitions,
  execute_tool = execute_tool,
}
