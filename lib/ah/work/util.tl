-- ah/work/util.tl: shared utilities for the work subsystem
local spawn = require("cosmic.child")
local env = require("cosmic.env")
local unix = require("cosmo.unix")

local function log(msg: string)
  io.stderr:write("[work] " .. msg .. "\n")
end

local function read_file(path: string): string
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

local function write_file(path: string, content: string): boolean
  local f = io.open(path, "w")
  if not f then return false end
  f:write(content)
  f:close()
  return true
end

-- Format a list of directories for AH_PROTECT_DIRS env var (colon-separated).
-- Returns nil when there are no directories to protect.
local function format_protect_dirs(dirs: {string}): string
  if not dirs or #dirs == 0 then return nil end
  return table.concat(dirs, ":")
end

-- Configure git identity env vars in the given environment table.
-- Uses GITHUB_ACTOR when available (GitHub Actions), otherwise falls back
-- to defaults. Does not overwrite values that are already set.
local function setup_git_env(run_env: {string:string})
  local actor = run_env.GITHUB_ACTOR
  local name = actor or "ah-agent"
  local email = actor and (actor .. "@users.noreply.github.com") or "ah-agent@localhost"

  if not run_env.GIT_AUTHOR_NAME then run_env.GIT_AUTHOR_NAME = name end
  if not run_env.GIT_AUTHOR_EMAIL then run_env.GIT_AUTHOR_EMAIL = email end
  if not run_env.GIT_COMMITTER_NAME then run_env.GIT_COMMITTER_NAME = name end
  if not run_env.GIT_COMMITTER_EMAIL then run_env.GIT_COMMITTER_EMAIL = email end
end

-- Format error from a failed command, preferring stderr over stdout.
local function format_run_error(prefix: string, stdout: string, stderr: string): string
  local detail: string
  if stderr and stderr ~= "" then
    detail = stderr
  elseif stdout and stdout ~= "" then
    detail = stdout
  else
    detail = "no output"
  end
  return prefix .. ": " .. detail
end

local function ah_exe(): string
  return arg and arg[-1] or "ah"
end

local function run(cmd: {string}): boolean, string, integer, string
  log("exec: " .. table.concat(cmd, " "))
  local handle, spawn_err = spawn.spawn(cmd, {env = env.all() as {string}})
  if not handle then
    log("spawn failed: " .. (spawn_err or "unknown"))
    return false, spawn_err as string, -1
  end
  local stderr_out = handle.stderr:read()
  local ok, stdout, exit_str = handle:read()
  local exit_code = (tonumber(exit_str) or 0) as integer
  if not (ok and exit_code == 0) then
    log("command failed (exit " .. tostring(exit_code) .. ")")
    if stdout and stdout ~= "" then
      log("stdout: " .. stdout:sub(1, 500))
    end
    if stderr_out and stderr_out ~= "" then
      log("stderr: " .. stderr_out:sub(1, 1000))
    end
  end
  return ok and exit_code == 0, stdout, exit_code, stderr_out
end

local function tee(path: string, line: string)
  print(line)
  local f = io.open(path, "a")
  if f then
    f:write(line .. "\n")
    f:close()
  end
end

local function slice(t: {string}, from: integer): {string}
  local result: {string} = {}
  for i = from, #t do
    result[#result + 1] = t[i]
  end
  return result
end

local function now_sec(): number
  local s, ns = unix.clock_gettime(unix.CLOCK_MONOTONIC)
  return s + ns / 1e9
end

-- Branch extraction
local function extract_branch(plan_contents: string, default_number: string): string
  return plan_contents:match("Branch: ([^\n]+)") or ("work/" .. default_number)
end

return {
  log = log,
  read_file = read_file,
  write_file = write_file,
  format_protect_dirs = format_protect_dirs,
  setup_git_env = setup_git_env,
  format_run_error = format_run_error,
  ah_exe = ah_exe,
  run = run,
  tee = tee,
  slice = slice,
  now_sec = now_sec,
  extract_branch = extract_branch,
}
