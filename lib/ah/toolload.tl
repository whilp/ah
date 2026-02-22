-- ah/toolload.tl: tool file loading, AST validation, and directory scanning
local fs = require("cosmic.fs")
local cio = require("cosmic.io")

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

-- Ensure the tl package searcher is installed. Called before any tl.load()
-- or tl.process_string() usage.
local function ensure_tl_searcher(): {string: any}
  local tl = require("tl") as {string: any}
  if not tl_searcher_installed then
    local tl_loader = tl.loader as function()
    tl_loader()
    tl_searcher_installed = true
  end
  return tl
end

-- Check whether source code looks like a tool module by parsing the AST
-- without evaluating it. This guards against os.exit() and other dangerous
-- top-level side effects in files that aren't tool modules.
--
-- Returns true if the file could be a tool module, false if it definitely
-- is not (wrong shape). Conservative: returns true for variable/call returns
-- that can't be statically verified — is_valid_tool catches those at runtime.
local function looks_like_tool(source: string, is_lua: boolean): boolean
  local tl = ensure_tl_searcher()
  local process_string = tl.process_string as function(string, boolean): {string: any}
  local result = process_string(source, is_lua)

  if result.syntax_errors and #(result.syntax_errors as {any}) > 0 then
    return false
  end

  local ast = result.ast as {any}
  if not ast or #ast == 0 then
    return false
  end

  local last = ast[#ast] as {string: any}
  if not last or last.kind ~= "return" then
    return false
  end

  -- Check if the return expression is a literal table with name + execute keys
  local exps = last.exps as {any}
  if exps and #exps > 0 then
    local ret = exps[1] as {string: any}
    if ret.kind == "literal_table" then
      local keys: {string: boolean} = {}
      for _, entry in ipairs(ret as {any}) do
        local e = entry as {string: any}
        if e.key then
          local key = e.key as {string: any}
          local k = (key.conststr or key.tk) as string
          if k then keys[k] = true end
        end
      end
      return (keys["name"] and keys["execute"]) as boolean
    end
  end

  -- Returns a variable or function call — can't verify statically.
  -- Let is_valid_tool catch bad shapes at runtime.
  return true
end

-- Load a tool module from a .tl or .lua file.
-- Returns the loaded chunk or nil + error string.
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

-- Tool record (re-declared here to avoid circular dependency with tools.tl)
local record Tool
  name: string
  description: string
  input_schema: {string: any}
  system_prompt: string
  running_processes: {integer: any}
  execute: function(input: {string: any}): string, boolean, any
end

-- Load lua/teal module tools from a directory.
-- .tl files take precedence over .lua files with the same basename.
local function load_custom_tools_from_dir(dir: string): {Tool}
  local loaded: {Tool} = {}

  local dh = fs.opendir(dir)
  if not dh then return loaded end

  -- Collect candidate files, .tl overrides .lua by basename
  local candidates: {string: string} = {} -- basename -> path
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
    -- Read source and check AST before evaluating — guards against os.exit()
    -- and other dangerous side effects in non-tool files.
    local source = cio.slurp(tool_path)
    if not source then
      io.stderr:write(string.format("warning: failed to read %s\n", tool_path))
    elseif not looks_like_tool(source, tool_path:match("%.lua$") ~= nil) then
      io.stderr:write(string.format("warning: skipping %s: does not look like a tool module\n", tool_path))
    else
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
  end

  return loaded
end

return {
  is_valid_tool = is_valid_tool,
  add_to_package_path = add_to_package_path,
  ensure_tl_searcher = ensure_tl_searcher,
  looks_like_tool = looks_like_tool,
  load_tool_file = load_tool_file,
  load_custom_tools_from_dir = load_custom_tools_from_dir,
  Tool = Tool,
}
