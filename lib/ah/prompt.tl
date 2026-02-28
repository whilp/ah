-- ah/prompt.tl: system prompt loading and project context
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local child = require("cosmic.child")

-- Run a git command in cwd with a 2s timeout. Returns trimmed stdout or nil.
-- Never throws. Any failure (not a repo, git missing, timeout, bad exit) returns nil.
local function git_cmd(cwd: string, ...: string): string
  local argv: {string} = {"timeout", "2", "git"}
  for i = 1, select("#", ...) do
    argv[#argv + 1] = select(i, ...) as string
  end
  local ok, result = pcall(function(): string
      local h, err = child.spawn(argv, {cwd = cwd})
      if not h then return nil end
      local success, stdout, _ = h:read()
      if not success then return nil end
      local out = (stdout as string) or ""
      if out == "" then return nil end
      return (out:gsub("%s+$", ""))
    end)
  if not ok then return nil end
  return result
end

-- Get git toplevel for cwd. Returns nil if not in a git repo.
local function git_toplevel(cwd: string): string
  return git_cmd(cwd, "rev-parse", "--show-toplevel")
end

-- Gather git context for the working directory. Each value is nil
-- when the command fails (not a git repo, git not installed, timeout).
local function git_context(cwd: string): {string: string}
  return {
    branch = git_cmd(cwd, "rev-parse", "--abbrev-ref", "HEAD"),
    commit = git_cmd(cwd, "rev-parse", "--short", "HEAD"),
    remote = git_cmd(cwd, "remote", "get-url", "origin"),
  }
end

-- Collect context file content for a single directory.
-- Checks CLAUDE.md first, then AGENTS.md. Returns content string or nil.
local function collect_context_file(dir: string): string
  local claude = cio.slurp(fs.join(dir, "CLAUDE.md"))
  if claude then return claude end
  local agents = cio.slurp(fs.join(dir, "AGENTS.md"))
  if agents then return agents end
  return nil
end

-- Load CLAUDE.md / AGENTS.md from cwd and all ancestor directories up to
-- git toplevel (or filesystem root). Results are concatenated from most
-- general (root) to most specific (cwd).
local function load_claude_md(cwd: string): string
  cwd = cwd or fs.getcwd()

  -- Determine stop directory: git toplevel or filesystem root.
  local stop = git_toplevel(cwd) or "/"

  -- Walk from cwd up to stop, collecting directories.
  local dirs: {string} = {}
  local dir = cwd
  while true do
    dirs[#dirs + 1] = dir
    if dir == stop then break end
    local parent = fs.dirname(dir)
    -- Reached filesystem root (dirname of "/" is "/").
    if parent == dir then break end
    dir = parent
  end

  -- Reverse so we go from most general (stop/root) to most specific (cwd).
  local n = #dirs
  for i = 1, math.floor(n / 2) do
    dirs[i], dirs[n - i + 1] = dirs[n - i + 1], dirs[i]
  end

  -- Collect non-empty context sections: {path, content} pairs.
  local section_paths: {string} = {}
  local section_contents: {string} = {}
  for _, d in ipairs(dirs) do
    local content = collect_context_file(d)
    if content then
      section_paths[#section_paths + 1] = d
      section_contents[#section_contents + 1] = content
    end
  end

  local count = #section_paths
  if count == 0 then return "" end

  -- Single result: use legacy headers for backward compatibility.
  if count == 1 then
    local is_claude = cio.slurp(fs.join(section_paths[1], "CLAUDE.md")) ~= nil
    local header = is_claude and "# Project Context" or "# Agent Context"
    return "\n\n" .. header .. "\n\n" .. section_contents[1]
  end

  -- Multiple results: label each with its source path.
  local parts: {string} = {}
  for i = 1, count do
    parts[#parts + 1] = "# Context from " .. section_paths[i] .. "\n\n" .. section_contents[i]
  end
  return "\n\n" .. table.concat(parts, "\n\n")
end

-- Load system prompt with precedence:
-- 1. /zip/embed/system.md (user override)
-- 2. /zip/embed/sys/system.md (ah default)
-- Project CLAUDE.md and AGENTS.md are always appended
local function load_system_prompt(cwd: string): string
  cwd = cwd or fs.getcwd()
  local claude_md = load_claude_md(cwd)

  local base: string
  local user_system = cio.slurp("/zip/embed/system.md")
  if user_system then
    base = user_system .. claude_md
  else
    local sys_system = cio.slurp("/zip/embed/sys/system.md")
    if sys_system then
      base = sys_system .. claude_md
    else
      base = claude_md
    end
  end

  -- Append runtime context (datetime, working directory, git info)
  local date_str = os.date("!%Y-%m-%dT%H:%M:%SZ") as string
  base = base .. "\n\nCurrent date: " .. date_str .. "\nWorking directory: " .. cwd

  local git = git_context(cwd)
  if git.branch then
    base = base .. "\nGit branch: " .. git.branch
  end
  if git.commit then
    base = base .. "\nGit commit: " .. git.commit
  end
  if git.remote then
    base = base .. "\nGit remote: " .. git.remote
  end

  return base
end

return {
  load_claude_md = load_claude_md,
  load_system_prompt = load_system_prompt,
}
