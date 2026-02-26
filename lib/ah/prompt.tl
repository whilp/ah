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

-- Gather git context for the working directory. Each value is nil
-- when the command fails (not a git repo, git not installed, timeout).
local function git_context(cwd: string): {string: string}
  return {
    branch = git_cmd(cwd, "rev-parse", "--abbrev-ref", "HEAD"),
    commit = git_cmd(cwd, "rev-parse", "--short", "HEAD"),
    remote = git_cmd(cwd, "remote", "get-url", "origin"),
  }
end

-- Load CLAUDE.md with embedded base prepended.
-- Walks from cwd up to git toplevel (or filesystem root) collecting
-- CLAUDE.md and AGENTS.md files. Concatenates them from most general
-- (root/git-top) to most specific (cwd). CLAUDE.md supersedes AGENTS.md
-- at each directory level.
local function load_claude_md(cwd: string): string
  cwd = cwd or fs.getcwd()

  -- Find the stop directory: git toplevel if available, else filesystem root.
  local stop = git_cmd(cwd, "rev-parse", "--show-toplevel") or "/"

  -- Collect entries from cwd upward to stop (inclusive).
  -- entries[1] is cwd-level, entries[N] is stop-level.
  local entries: {{string: string}} = {}
  local dir = cwd
  while true do
    local claude = cio.slurp(fs.join(dir, "CLAUDE.md"))
    if claude then
      entries[#entries + 1] = {header = "# Project Context", content = claude}
    else
      local agents = cio.slurp(fs.join(dir, "AGENTS.md"))
      if agents then
        entries[#entries + 1] = {header = "# Agent Context", content = agents}
      end
    end
    -- Stop when we've processed the stop dir or reached filesystem root.
    if dir == stop or dir == "/" then break end
    local parent = fs.dirname(dir)
    -- Safety: if dirname doesn't advance, we're stuck at root.
    if parent == dir then break end
    dir = parent
  end

  if #entries == 0 then return "" end

  -- Reverse: most general (stop dir) first, most specific (cwd) last.
  local parts: {string} = {}
  for i = #entries, 1, -1 do
    local e = entries[i]
    parts[#parts + 1] = "\n\n" .. e.header .. "\n\n" .. e.content
  end
  return table.concat(parts)
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
