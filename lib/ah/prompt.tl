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

-- Collect one context snippet for a single directory.
-- Prefers CLAUDE.md over AGENTS.md. Returns nil when neither exists.
local function load_context_for_dir(dir: string): string
  local project_claude = cio.slurp(fs.join(dir, "CLAUDE.md"))
  if project_claude then
    return "\n\n# Project Context\n\n" .. project_claude
  end
  local agents_md = cio.slurp(fs.join(dir, "AGENTS.md"))
  if agents_md then
    return "\n\n# Agent Context\n\n" .. agents_md
  end
  return nil
end

-- Load CLAUDE.md / AGENTS.md from cwd and all ancestor directories up to the
-- git toplevel (or filesystem root). Results are concatenated from most general
-- (root) to most specific (cwd), so cwd content appears last and can override.
local function load_claude_md(cwd: string): string
  cwd = cwd or fs.getcwd()

  -- Determine the stop directory: git toplevel if available, else "/".
  local stop_dir = git_cmd(cwd, "rev-parse", "--show-toplevel") or "/"

  -- Walk from cwd up to stop_dir (inclusive), collecting dirs.
  local dirs: {string} = {}
  local dir = cwd
  local max_steps = 64 -- safety limit
  for _ = 1, max_steps do
    dirs[#dirs + 1] = dir
    if dir == stop_dir then break end
    local parent = fs.dirname(dir)
    if parent == dir then break end -- reached filesystem root
    dir = parent
  end

  -- Reverse so root comes first (most general → most specific).
  local lo = 1
  local hi = #dirs
  while lo < hi do
    dirs[lo], dirs[hi] = dirs[hi], dirs[lo]
    lo = lo + 1
    hi = hi - 1
  end

  -- Collect context snippets.
  local parts: {string} = {}
  for _, d in ipairs(dirs) do
    local snippet = load_context_for_dir(d)
    if snippet then
      parts[#parts + 1] = snippet
    end
  end

  return table.concat(parts, "")
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
