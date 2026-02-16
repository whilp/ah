-- ah/tools.tl: agent tools (read, write, edit, bash)
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local child = require("cosmic.child")
local codec = require("cosmic.codec")
local signal = require("cosmic.signal")
local time = require("cosmic.time")
local json = require("cosmic.json")
local env = require("cosmic.env")

-- Track running process handles for abort cleanup
-- Maps pid -> process handle for active bash commands
local running_processes: {integer: any} = {}

-- Image extension to media type mapping
local IMAGE_TYPES: {string:string} = {
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  png = "image/png",
  gif = "image/gif",
  webp = "image/webp",
}

-- Check if content appears to be binary (contains null bytes or high ratio of non-printable chars)
local function is_binary(content: string): boolean
  -- Check first 8KB for null bytes or excessive non-printable characters
  local sample_size = math.min(#content, 8192)
  local sample = content:sub(1, sample_size)

  -- Null byte is a strong indicator of binary
  if sample:find("\0") then
    return true
  end

  -- Count non-printable, non-whitespace characters
  local non_printable = 0
  for i = 1, #sample do
    local b = sample:byte(i)
    -- Allow printable ASCII (32-126), tab (9), newline (10), carriage return (13)
    if not ((b >= 32 and b <= 126) or b == 9 or b == 10 or b == 13) then
      -- Also allow valid UTF-8 continuation bytes (128-255)
      if b < 128 then
        non_printable = non_printable + 1
      end
    end
  end

  -- If more than 10% is non-printable ASCII control chars, likely binary
  return non_printable > sample_size * 0.1
end

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
end

local record Tool
  name: string
  description: string
  input_schema: {string:any}
  system_prompt: string
  execute: function(input: {string:any}): string, boolean, ToolDetails
end

-- Custom tools loaded at runtime
local custom_tools: {Tool} = {}

-- Read file tool
local read_tool: Tool = {
  name = "read",
  description = "Read contents of a file (supports text and images: jpg, png, gif, webp)",
  system_prompt = "Use read to examine files before editing. Do not use cat to read files.",
  input_schema = {
    type = "object",
    properties = {
      path = {type = "string", description = "Path to file to read"},
      offset = {type = "integer", description = "Line number to start reading from (1-indexed, text only)"},
      limit = {type = "integer", description = "Maximum number of lines to read (text only)"},
    },
    required = {"path"},
  },
  execute = function(input: {string:any}): string, boolean, ToolDetails
    local file_path = input.path as string
    if not file_path then
      return "error: path is required", true, nil
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
        return "error: failed to read file: " .. file_path, true, nil
      end

      local base64_data = codec.encode_base64(content)
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
      return json.encode(image_block), false, {path = file_path, bytes = #content, media_type = media_type} as ToolDetails
    end

    -- Text file handling
    local content = cio.slurp(file_path)
    if not content then
      return "error: failed to read file: " .. file_path, true, nil
    end

    -- Check for binary content
    if is_binary(content) then
      return string.format("error: %s appears to be a binary file (%d bytes)", file_path, #content), true, nil
    end

    local offset = (input.offset as integer) or 1
    local limit = (input.limit as integer) or 0

    -- Count total lines
    local total_lines = 0
    for _ in content:gmatch("[^\n]*") do
      total_lines = total_lines + 1
    end

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
      return table.concat(lines, "\n"), false, {path = file_path, line_count = total_lines} as ToolDetails
    end

    -- Add line numbers
    local lines: {string} = {}
    local line_num = 0
    for line in content:gmatch("[^\n]*") do
      line_num = line_num + 1
      table.insert(lines, string.format("%d\t%s", line_num, line))
    end
    return table.concat(lines, "\n"), false, {path = file_path, line_count = total_lines} as ToolDetails
  end,
}

-- Write file tool
local write_tool: Tool = {
  name = "write",
  description = "Write content to a file (creates or overwrites)",
  system_prompt = "Output plain text directly — do not use cat or bash to display what you wrote.\nPrefer editing existing files over creating new ones.",
  input_schema = {
    type = "object",
    properties = {
      path = {type = "string", description = "Path to file to write"},
      content = {type = "string", description = "Content to write"},
    },
    required = {"path", "content"},
  },
  execute = function(input: {string:any}): string, boolean, ToolDetails
    local file_path = input.path as string
    local content = input.content as string

    if not file_path then
      return "error: path is required", true, nil
    end
    if not content then
      return "error: content is required", true, nil
    end

    -- Create parent directories if needed
    local dir = fs.dirname(file_path)
    if dir and dir ~= "" then
      local mk_ok, mk_err = fs.makedirs(dir)
      if not mk_ok then
        return "error: failed to create directory: " .. dir .. ": " .. (mk_err or ""), true, nil
      end
    end

    local ok = cio.barf(file_path, content, tonumber("644", 8))
    if not ok then
      return "error: failed to write file: " .. file_path, true, nil
    end

    -- Count lines for display
    local line_count = 1
    for _ in content:gmatch("\n") do line_count = line_count + 1 end

    return string.format("%d lines", line_count), false,
      {path = file_path, bytes = #content, line_count = line_count} as ToolDetails
  end,
}

-- Edit file tool
local edit_tool: Tool = {
  name = "edit",
  description = "Replace text in a file (old_string must be unique)",
  system_prompt = "The old_string in edit must match the file contents exactly, including whitespace and indentation.\nIf an edit fails with \"old_string is not unique\", re-read the file and include more surrounding context lines in old_string to disambiguate.\nDo not use sed to edit files.",
  input_schema = {
    type = "object",
    properties = {
      path = {type = "string", description = "Path to file to edit"},
      old_string = {type = "string", description = "Text to find and replace"},
      new_string = {type = "string", description = "Replacement text"},
    },
    required = {"path", "old_string", "new_string"},
  },
  execute = function(input: {string:any}): string, boolean, ToolDetails
    local file_path = input.path as string
    local old_string = input.old_string as string
    local new_string = input.new_string as string

    if not file_path then
      return "error: path is required", true, nil
    end
    if not old_string then
      return "error: old_string is required", true, nil
    end
    if new_string == nil then
      return "error: new_string is required", true, nil
    end

    local content = cio.slurp(file_path)
    if not content then
      return "error: failed to read file: " .. file_path, true, nil
    end

    -- Check uniqueness
    local _, count = content:gsub(old_string:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1"), "")
    if count == 0 then
      return "error: old_string not found in file", true, nil
    end
    if count > 1 then
      return "error: old_string is not unique (found " .. count .. " times)", true, nil
    end

    -- Count lines in old and new strings
    local old_lines = 1
    for _ in old_string:gmatch("\n") do old_lines = old_lines + 1 end
    local new_lines = 1
    for _ in new_string:gmatch("\n") do new_lines = new_lines + 1 end

    -- Perform replacement (escape % in replacement string)
    local escaped_new = new_string:gsub("%%", "%%%%")
    local new_content = content:gsub(old_string:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1"), escaped_new, 1)

    local ok = cio.barf(file_path, new_content, tonumber("644", 8))
    if not ok then
      return "error: failed to write file: " .. file_path, true, nil
    end

    -- Build compact diff for display
    local diff_lines: {string} = {}
    for line in old_string:gmatch("([^\n]*)\n?") do
      if line ~= "" or old_string:find("\n") then
        table.insert(diff_lines, "- " .. line)
      end
    end
    -- Remove trailing empty line artifact from pattern
    if #diff_lines > 0 and diff_lines[#diff_lines] == "- " and not old_string:match("\n$") then
      table.remove(diff_lines)
    end
    for line in new_string:gmatch("([^\n]*)\n?") do
      if line ~= "" or new_string:find("\n") then
        table.insert(diff_lines, "+ " .. line)
      end
    end
    if #diff_lines > 0 and diff_lines[#diff_lines] == "+ " and not new_string:match("\n$") then
      table.remove(diff_lines)
    end
    local result = table.concat(diff_lines, "\n")
    if result == "" then
      result = "edited " .. file_path
    end

    return result, false,
      {path = file_path, old_lines = old_lines, new_lines = new_lines} as ToolDetails
  end,
}

-- Find executable in PATH or common locations
-- Returns absolute path or nil if not found
local function find_executable(name: string): string
  -- Check AH_* env override first (e.g., AH_SHELL, AH_TIMEOUT)
  local env_override = os.getenv("AH_" .. name:upper())
  if env_override then
    return env_override
  end

  -- Common absolute paths to check
  local common_paths: {string} = {
    "/usr/bin/" .. name,
    "/bin/" .. name,
    "/usr/local/bin/" .. name,
  }

  for _, path in ipairs(common_paths) do
    local f = io.open(path, "r")
    if f then
      f:close()
      return path
    end
  end

  -- Fall back to bare name (relies on PATH)
  return name
end

-- Bash tool
local bash_tool: Tool = {
  name = "bash",
  description = "Execute a bash command",
  system_prompt = "Use bash for system commands, not for file operations.\nAll tools run in the working directory. Use relative paths for project files.",
  input_schema = {
    type = "object",
    properties = {
      command = {type = "string", description = "Command to execute"},
      timeout = {type = "integer", description = "Timeout in milliseconds (default: 120000)"},
    },
    required = {"command"},
  },
  execute = function(input: {string:any}): string, boolean, ToolDetails
    local command = input.command as string
    if not command then
      return "error: command is required", true, nil
    end

    -- Timeout in milliseconds, default 120000 (2 minutes)
    local timeout_ms = (input.timeout as integer) or 120000
    local timeout_sec = math.ceil(timeout_ms / 1000)

    -- Spawn directly: timeout -> shell -> command
    -- No double-wrapping (old: sh -c "timeout N sh -c %q") which corrupted
    -- newlines via %q escaping (backslash-newline becomes line continuation).
    -- Use absolute paths to avoid PATH lookup issues in sandbox environments.
    local shell = find_executable(os.getenv("AH_SHELL") or "bash")
    local timeout_cmd = find_executable("timeout")
    local handle, err = child.spawn(
      {timeout_cmd, tostring(timeout_sec), shell, "-c", command},
      {env = env.all() as {string}}
    )
    if not handle then
      return "error: failed to spawn: " .. tostring(err), true, nil
    end

    -- Track the running process for abort cleanup
    local pid = (handle as {string:any}).pid as integer
    if pid then
      running_processes[pid] = handle
    end

    -- Read output: h:read() returns (ok, stdout, exit_code_as_string)
    local ok, stdout, exit_str = handle:read()

    -- Untrack the process after completion
    if pid then
      running_processes[pid] = nil
    end

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

    return result, exit_code ~= 0,
      {command = command, exit_code = exit_code} as ToolDetails
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
  local handle, err = child.spawn({"test", "-x", path}, {env = env.all() as {string}})
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

-- Load CLI tools from a bin directory
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

    -- Skip non-executables and .md files
    if name:match("%.md$") then goto continue end
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
      local handle = child.spawn({bin_path, "--help"}, {env = env.all() as {string}})
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

        -- Parse args string into array (simple space-split, respects quotes)
        local cmd = {tool_path}
        for arg in args_str:gmatch("%S+") do
          table.insert(cmd, arg)
        end

        local handle, err = child.spawn(cmd, {env = env.all() as {string}})
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
local function merge_tools(by_name: {string:Tool}, tools: {Tool})
  for _, tool in ipairs(tools) do
    by_name[tool.name] = tool
  end
end

-- Initialize custom tools from standard locations.
-- Later sources override earlier ones by name:
--   1. system (/zip/embed/sys/tools)
--   2. embed  (/zip/embed/tools)
--   3. project (cwd/tools/ — both .lua modules and executables)
local function init_custom_tools(cwd?: string)
  cwd = cwd or fs.getcwd()

  local by_name: {string:Tool} = {}

  -- System tier: lua modules
  merge_tools(by_name, load_custom_tools_from_dir("/zip/embed/sys/tools"))

  -- Embed tier: lua modules
  merge_tools(by_name, load_custom_tools_from_dir("/zip/embed/tools"))

  -- Project tier: lua modules + executables from cwd/tools/
  local project_tools_dir = fs.join(cwd, "tools")
  merge_tools(by_name, load_custom_tools_from_dir(project_tools_dir))
  merge_tools(by_name, load_cli_tools_from_dir(project_tools_dir))

  custom_tools = {}
  for _, tool in pairs(by_name) do
    table.insert(custom_tools, tool)
  end
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
  -- Custom tools (lua + CLI) can override builtin
  for _, tool in ipairs(custom_tools) do
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

-- Format tool guidance for inclusion in the system prompt.
-- Generates a "Tools:" summary line and appends any per-tool system_prompt bodies.
local function format_tools_for_prompt(): string
  local all = get_all_tools()
  if #all == 0 then return "" end

  -- Sorted tool names for deterministic output
  table.sort(all, function(a: Tool, b: Tool): boolean
    return a.name < b.name
  end)

  local names: {string} = {}
  for _, tool in ipairs(all) do
    table.insert(names, tool.name)
  end

  local parts: {string} = {}
  table.insert(parts, "Tools: " .. table.concat(names, ", ") .. ".")

  -- Brief description line for each tool
  for _, tool in ipairs(all) do
    table.insert(parts, tool.name .. ": " .. tool.description)
  end

  -- Append per-tool system_prompt guidance
  for _, tool in ipairs(all) do
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
  load_custom_tools_from_dir = load_custom_tools_from_dir,
  load_cli_tools_from_dir = load_cli_tools_from_dir,
  is_valid_tool = is_valid_tool,
  Tool = Tool,
  ToolDetails = ToolDetails,
}
