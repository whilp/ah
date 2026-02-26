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

-- Load CLAUDE.md with embedded base prepended
local function load_claude_md(cwd: string): string
  cwd = cwd or fs.getcwd()

  -- Find the git toplevel to use as the stop point. If not in a git repo,
  -- walk all the way to the filesystem root.
  local git_root = git_cmd(cwd, "rev-parse", "--show-toplevel")

  -- Collect ancestor directories from cwd up to the stop point (inclusive).
  local dirs: {string} = {}
  local dir = cwd
  while true do
    dirs[#dirs + 1] = dir
    -- Stop if we've reached the git root or filesystem root.
    if (git_root and dir == git_root) or dir == "/" then
      break
    end
    local parent = fs.dirname(dir)
    -- Guard against infinite loop at filesystem root.
    if parent == dir then
      break
    end
    dir = parent
  end

  -- Reverse so order is root → cwd (most general first).
  local reversed: {string} = {}
  for i = #dirs, 1, -1 do
    reversed[#reversed + 1] = dirs[i]
  end

  -- For each directory, collect context: CLAUDE.md supersedes AGENTS.md within
  -- the same directory.
  local parts: {string} = {}
  for _, d in ipairs(reversed) do
    local project_claude = cio.slurp(fs.join(d, "CLAUDE.md"))
    if project_claude then
      parts[#parts + 1] = "\n\n# Project Context\n\n" .. project_claude
    else
      local agents_md = cio.slurp(fs.join(d, "AGENTS.md"))
      if agents_md then
        parts[#parts + 1] = "\n\n# Agent Context\n\n" .. agents_md
      end
    end
  end

  local result = ""
  for _, p in ipairs(parts) do
    result = result .. p
  end
  return result
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
