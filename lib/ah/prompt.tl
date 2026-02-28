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

-- Build a markdown section describing active sandbox restrictions.
-- Reads AH_SANDBOX, AH_UNVEIL, AH_PROTECT_DIRS, AH_ALLOW_HOSTS env vars.
-- Accepts optional env override table for testability. When provided,
-- only the override table is consulted (os.getenv is not called).
local function sandbox_context(env: {string: string} | nil): string
  local use_override = env ~= nil
  local env_table: {string: string} = env or {}
  local function getenv(key: string): string
    if use_override then
      return env_table[key]
    end
    return os.getenv(key)
  end

  if not getenv("AH_SANDBOX") then
    return ""
  end

  local lines: {string} = {"## Sandbox"}

  -- Command / argv
  local argv_parts: {string} = {}
  if arg and (arg as {integer: string})[-1] then
    argv_parts[#argv_parts + 1] = (arg as {integer: string})[-1]
  end
  if arg and (arg as {integer: string})[0] then
    argv_parts[#argv_parts + 1] = (arg as {integer: string})[0]
  end
  if arg then
    local i = 1
    while (arg as {integer: string})[i] do
      argv_parts[#argv_parts + 1] = (arg as {integer: string})[i]
      i = i + 1
    end
  end
  if #argv_parts > 0 then
    lines[#lines + 1] = "\n**Command**: `" .. table.concat(argv_parts, " ") .. "`"
  end

  -- Pledge promises (always the same when AH_SANDBOX=1)
  local promises = "stdio rpath wpath cpath flock tty proc exec execnative unix prot_exec"
  lines[#lines + 1] = "\n**Pledge**: `" .. promises .. "`"

  -- Unveiled paths: system defaults + user-supplied
  lines[#lines + 1] = "\n**Unveiled paths**:"
  local cwd = getenv("PWD") or "."
  local system_unveils: {{string}} = {
    {cwd, "rwxc"},
    {"/tmp", "rwxc"},
    {"/usr", "rx"},
    {"/bin", "rx"},
    {"/lib", "rx"},
    {"/lib64", "rx"},
    {"/etc/ssl", "r"},
    {"/etc/resolv.conf", "r"},
    {"/dev/null", "rw"},
    {"/dev/tty", "rw"},
    {"/proc/self", "r"},
  }
  local home = getenv("HOME")
  if home then
    system_unveils[#system_unveils + 1] = {home, "r"}
  end

  -- Collect protect dirs (downgrade to read-only)
  local protect_set: {string: boolean} = {}
  local protect_env = getenv("AH_PROTECT_DIRS")
  if protect_env then
    for dir in protect_env:gmatch("[^:]+") do
      protect_set[cwd .. "/" .. dir] = true
    end
  end

  for _, entry in ipairs(system_unveils) do
    local u_path = entry[1]
    local u_perms = entry[2]
    if protect_set[u_path] then
      u_perms = "r"
    end
    lines[#lines + 1] = "- `" .. u_path .. "` (" .. u_perms .. ")"
  end

  -- User-supplied unveil paths from AH_UNVEIL
  local unveil_env = getenv("AH_UNVEIL")
  if unveil_env then
    for raw in unveil_env:gmatch("[^,]+") do
      local colon = raw:find(":", 1, true)
      if colon then
        local u_path = raw:sub(1, colon - 1)
        local u_perms = raw:sub(colon + 1)
        if u_path:sub(1, 1) ~= "/" then
          u_path = cwd .. "/" .. u_path
        end
        lines[#lines + 1] = "- `" .. u_path .. "` (" .. u_perms .. ") [user]"
      end
    end
  end

  -- Network: always anthropic, plus user-supplied hosts
  lines[#lines + 1] = "\n**Allowed network hosts**:"
  lines[#lines + 1] = "- `api.anthropic.com:443`"
  local allow_env = getenv("AH_ALLOW_HOSTS")
  if allow_env then
    for host in allow_env:gmatch("[^,]+") do
      lines[#lines + 1] = "- `" .. host .. "` [user]"
    end
  end

  return table.concat(lines, "\n")
end

return {
  load_claude_md = load_claude_md,
  load_system_prompt = load_system_prompt,
  sandbox_context = sandbox_context,
}
