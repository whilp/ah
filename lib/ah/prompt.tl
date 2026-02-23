-- ah/prompt.tl: system prompt loading and project context
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local child = require("cosmic.child")

-- Load CLAUDE.md with embedded base prepended
local function load_claude_md(cwd: string): string
  cwd = cwd or fs.getcwd()

  -- CLAUDE.md supersedes AGENTS.md when both exist.
  -- Projects should pick one file; CLAUDE.md is the conventional name.
  local project_claude = cio.slurp(fs.join(cwd, "CLAUDE.md"))
  if project_claude then
    return "\n\n# Project Context\n\n" .. project_claude
  end

  local agents_md = cio.slurp(fs.join(cwd, "AGENTS.md"))
  if agents_md then
    return "\n\n# Agent Context\n\n" .. agents_md
  end

  return ""
end

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

local record SandboxOpts
  enabled: boolean
  argv: {string}
  unveil_dirs: {string}
  allow_hosts: {string}
  pledge_promises: string
  protect_dirs: {string}
end

-- Format sandbox context for the system prompt.
-- Returns empty string when opts.enabled is false/nil.
local function format_sandbox_context(opts: SandboxOpts): string
  if not opts or not opts.enabled then return "" end

  local parts: {string} = {"## Sandbox"}

  -- Command / argv
  if opts.argv and #opts.argv > 0 then
    parts[#parts + 1] = "\nCommand: " .. table.concat(opts.argv, " ")
  end

  -- Filesystem (unveil)
  if opts.unveil_dirs and #opts.unveil_dirs > 0 then
    parts[#parts + 1] = "\n### Filesystem (unveil)"
    for _, entry in ipairs(opts.unveil_dirs) do
      parts[#parts + 1] = "- " .. entry
    end
  end

  -- Network (proxy allowlist)
  if opts.allow_hosts and #opts.allow_hosts > 0 then
    parts[#parts + 1] = "\n### Network (proxy allowlist)"
    for _, host in ipairs(opts.allow_hosts) do
      parts[#parts + 1] = "- " .. host
    end
  end

  -- Syscalls (pledge)
  if opts.pledge_promises and opts.pledge_promises ~= "" then
    parts[#parts + 1] = "\n### Syscalls (pledge)\n" .. opts.pledge_promises
  end

  return table.concat(parts, "\n")
end

return {
  load_claude_md = load_claude_md,
  load_system_prompt = load_system_prompt,
  format_sandbox_context = format_sandbox_context,
  SandboxOpts = SandboxOpts,
}
