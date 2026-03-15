-- ah/highlight.tl: external tool integration for syntax highlighting and rendering
-- Provides difftool (delta), pager (bat), and markdown renderer (glow).
local tty = require("cosmic.tty")
local child = require("cosmic.child")
local unix = require("cosmo.unix")
local cenv = require("cosmic.env")

-- ToolFinder holds a find function and a reset function for a cached tool lookup.
local record ToolFinder
  find: function(): string
  reset: function()
end

-- make_tool_finder returns a ToolFinder that checks env_var, then candidates, then PATH.
local function make_tool_finder(env_var: string, candidates: {string}, tool_names: {string}): ToolFinder
  local cache: string | boolean = nil

  local function find(): string
    if cache ~= nil then
      if cache == false then
        return nil
      end
      return cache as string
    end

    local env_tool = cenv.get(env_var)
    if env_tool and env_tool ~= "" then
      cache = env_tool
      return env_tool
    end

    for _, path in ipairs(candidates) do
      local f = io.open(path, "r")
      if f then
        f:close()
        cache = path
        return path
      end
    end

    for _, name in ipairs(tool_names) do
      local result = unix.commandv(name)
      if result then
        cache = result
        return result
      end
    end

    cache = false
    return nil
  end

  local function reset()
    cache = nil
  end

  return {find = find, reset = reset}
end

-- run_piped passes content via stdin to tool with extra_args.
-- Optional env_overrides: {"KEY=VALUE", ...} merged into the current environment.
local function run_piped(tool: string, content: string, extra_args: {string}, env_overrides?: {string}): string
  if not tool or content == "" then
    return nil
  end

  -- Build argv
  local argv: {string} = {tool}
  if extra_args then
    for _, arg in ipairs(extra_args) do
      table.insert(argv, arg)
    end
  end

  -- Build environment if overrides specified
  local env: {string} = nil
  if env_overrides then
    env = unix.environ() as {string}
    for _, override in ipairs(env_overrides) do
      local key = (override as string):match("^([^=]+)=")
      if key then
        local prefix = key .. "="
        local found = false
        for i, entry in ipairs(env) do
          if (entry as string):sub(1, #prefix) == prefix then
            env[i] = override
            found = true
            break
          end
        end
        if not found then
          table.insert(env, override)
        end
      end
    end
  end

  local h, _ = child.spawn(argv, {stdin = content, env = env})
  if not h then
    return nil
  end
  -- Ignore exit code: tools like delta exit 1 on diffs but stdout is valid.
  local _, stdout, _ = h:read()
  local output = (stdout as string) or ""
  if output == "" then
    return nil
  end
  return output
end

-- difftool: delta
local _difftool = make_tool_finder("AH_DIFFTOOL",
  {"/usr/bin/delta", "/usr/local/bin/delta", "/opt/homebrew/bin/delta"}, {"delta"})

local function find_difftool(): string return _difftool.find() end
local function reset_difftool_cache() _difftool.reset() end

-- Base delta args: no external config, diff-so-fancy style.
-- Syntax-highlighted with muted background colors:
--   removed lines: dark red background (#3f1515), emphasis (#6b2020)
--   added lines: dark blue background (#0d2744), emphasis (#133d6b)
local DELTA_BASE_ARGS: {string} = {
  "--no-gitconfig",
  "--diff-so-fancy",
  "--paging=never",
  "--syntax-theme=base16",
  '--minus-style=syntax "#3f1515"',
  '--minus-emph-style=syntax "#6b2020"',
  '--plus-style=syntax "#0d2744"',
  '--plus-emph-style=syntax "#133d6b"',
  "--file-style=omit",
  "--hunk-header-decoration-style=blue",
}

-- Map file extensions to delta --default-language values.
-- Only needed for extensions delta/syntect don't recognize natively.
local EXT_LANG_MAP: {string: string} = {
  tl = "Lua",
}

-- Map shebang interpreters to delta --default-language values.
local SHEBANG_LANG_MAP: {string: string} = {
  cosmic = "Lua",
}

-- Infer language from a file path's extension via EXT_LANG_MAP,
-- falling back to shebang detection in content.
local function infer_language(path: string, content?: string): string
  if path then
    local ext = path:match("%.([^%.]+)$")
    if ext and EXT_LANG_MAP[ext] then return EXT_LANG_MAP[ext] end
  end
  if content then
    local interp = content:match("^#!.-/([%w_%-]+)%s*\n")
    or content:match("^#!.-/env%s+([%w_%-]+)")
    if interp and SHEBANG_LANG_MAP[interp] then
      return SHEBANG_LANG_MAP[interp]
    end
  end
  return nil
end

local function run_difftool(difftool: string, diff_text: string, extra_args?: {string}, language?: string): string
  local args: {string} = {}
  for _, a in ipairs(DELTA_BASE_ARGS) do table.insert(args, a) end
  if language then
    table.insert(args, "--default-language=" .. language)
  end
  if extra_args then
    for _, a in ipairs(extra_args) do table.insert(args, a) end
  end
  return run_piped(difftool, diff_text, args)
end

-- Convert edit tool pseudo-diff to unified diff for delta.
local function to_unified_diff(pseudo_diff: string, file_path: string): string
  if not pseudo_diff or pseudo_diff == "" or not file_path or file_path == "" then
    return nil
  end

  local old_count = 0
  local new_count = 0
  local unified_lines: {string} = {}

  for line in pseudo_diff:gmatch("([^\n]*)\n?") do
    if line:sub(1, 2) == "- " then
      old_count = old_count + 1
      table.insert(unified_lines, "-" .. line:sub(3))
    elseif line:sub(1, 2) == "+ " then
      new_count = new_count + 1
      table.insert(unified_lines, "+" .. line:sub(3))
    elseif line ~= "" then
      -- Not a pseudo-diff line; bail out
      return nil
    end
  end

  if old_count == 0 and new_count == 0 then
    return nil
  end

  local header = "diff --git a/" .. file_path .. " b/" .. file_path .. "\n"
  .. "--- a/" .. file_path .. "\n"
  .. "+++ b/" .. file_path .. "\n"
  .. "@@ -1," .. old_count .. " +1," .. new_count .. " @@\n"

  return header .. table.concat(unified_lines, "\n") .. "\n"
end

-- glow: markdown renderer
local _glow = make_tool_finder("AH_GLOW",
  {"/usr/bin/glow", "/usr/local/bin/glow", "/opt/homebrew/bin/glow"}, {"glow"})

local function find_glow(): string return _glow.find() end
local function reset_glow_cache() _glow.reset() end

-- Resolve the glow style: extract embedded JSON to a temp file (external glow
-- cannot read /zip/ paths), or fall back to "dark".
local _glow_style: string = nil
local function glow_style(): string
  if _glow_style then return _glow_style end
  local embedded = "/zip/embed/sys/glow.json"
  local f = io.open(embedded, "r")
  if f then
    local content = f:read("*a")
    f:close()
    if content and content ~= "" then
      local tmpdir = cenv.get("TMPDIR") or "/tmp"
      local tmppath = tmpdir .. "/ah-glow-style.json"
      local out = io.open(tmppath, "w")
      if out then
        out:write(content)
        out:close()
        _glow_style = tmppath
        return _glow_style
      end
    end
  end
  _glow_style = "dark"
  return _glow_style
end

local function run_glow(glow: string, text: string): string
  local width = "0"
  local ws = tty.winsize(1) -- stdout
  if ws then
    width = tostring(ws.cols as integer)
  end
  -- CLICOLOR_FORCE=1 ensures glow emits ANSI colors even when piped.
  return run_piped(glow, text, {"-s", glow_style(), "-w", width, "-"}, {"CLICOLOR_FORCE=1"})
end

-- pager: bat
local _pager = make_tool_finder("AH_PAGER",
  {"/usr/bin/bat", "/usr/local/bin/bat", "/opt/homebrew/bin/bat"}, {"bat"})

local function find_pager(): string return _pager.find() end
local function reset_pager_cache() _pager.reset() end

-- Run content through bat with syntax highlighting.
-- Strips line number prefixes (N\t) before highlighting; does not re-add them.
local function run_pager(pager: string, content: string, file_name: string): string
  if not file_name or file_name == "" then
    return nil
  end

  -- Strip line number prefixes (N\t) from tool output
  local stripped = content:gsub("([^\n]*)", function(line: string): string
      local _, rest = line:match("^(%d+)\t(.*)$")
      if rest then
        return rest
      end
      return line
    end)

  local highlighted = run_piped(pager, stripped, {"--file-name=" .. file_name, "--color=always", "--style=plain", "--map-syntax=*.tl:Lua"})
  return highlighted
end

return {
  find_difftool = find_difftool,
  run_difftool = run_difftool,
  to_unified_diff = to_unified_diff,
  reset_difftool_cache = reset_difftool_cache,
  DELTA_BASE_ARGS = DELTA_BASE_ARGS,
  infer_language = infer_language,
  find_glow = find_glow,
  run_glow = run_glow,
  glow_style = glow_style,
  reset_glow_cache = reset_glow_cache,
  find_pager = find_pager,
  run_pager = run_pager,
  reset_pager_cache = reset_pager_cache,
}
