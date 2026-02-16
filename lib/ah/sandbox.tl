-- ah/sandbox.tl: sandbox supervisor for --sandbox mode
--
-- manages the lifecycle of a sandboxed child process: starts the proxy,
-- builds the child environment, and provides stdin preparation.

local spawn = require("cosmic.child")
local env = require("cosmic.env")
local cfs = require("cosmic.fs")
local time = require("cosmic.time")
local signal = require("cosmic.signal")

-- Sandbox context for network isolation
local record SandboxCtx
  enabled: boolean
  socket_path: string
  proxy_pid: number
  tmpdir: string
end

-- Look up an environment variable in the env array.
local function env_get(run_env: {string}, key: string): string
  local prefix = key .. "="
  for _, entry in ipairs(run_env) do
    if entry:sub(1, #prefix) == prefix then
      return entry:sub(#prefix + 1)
    end
  end
  return nil
end

-- Set an environment variable in the env array.
local function env_set(run_env: {string}, key: string, value: string)
  table.insert(run_env, key .. "=" .. value)
end

-- Configure git identity env vars in the given environment array.
local function setup_git_env(run_env: {string})
  local actor = env_get(run_env, "GITHUB_ACTOR")
  local name = actor or "ah-agent"
  local email = actor and (actor .. "@users.noreply.github.com") or "ah-agent@localhost"

  if not env_get(run_env, "GIT_AUTHOR_NAME") then env_set(run_env, "GIT_AUTHOR_NAME", name) end
  if not env_get(run_env, "GIT_AUTHOR_EMAIL") then env_set(run_env, "GIT_AUTHOR_EMAIL", email) end
  if not env_get(run_env, "GIT_COMMITTER_NAME") then env_set(run_env, "GIT_COMMITTER_NAME", name) end
  if not env_get(run_env, "GIT_COMMITTER_EMAIL") then env_set(run_env, "GIT_COMMITTER_EMAIL", email) end
  if not env_get(run_env, "GIT_CONFIG_GLOBAL") then env_set(run_env, "GIT_CONFIG_GLOBAL", "/dev/null") end
  if not env_get(run_env, "GIT_CONFIG_NOSYSTEM") then env_set(run_env, "GIT_CONFIG_NOSYSTEM", "1") end
end

-- Get the path to the ah executable.
local function ah_exe(): string
  return arg and arg[-1] or "ah"
end

-- Start sandbox proxy.
-- Returns sandbox context or nil on error.
local function start_sandbox(): SandboxCtx, string
  local tmpdir = cfs.mkdtemp("/tmp/ah-sandbox-XXXXXX")
  if not tmpdir then
    return nil, "failed to create temp directory"
  end

  local socket_path = tmpdir .. "/proxy.sock"

  local exe = ah_exe()
  local pid = spawn.fork()
  if pid < 0 then
    cfs.rmrf(tmpdir)
    return nil, "fork failed"
  end

  if pid == 0 then
    require("cosmic.proc").execve(exe, {exe, "proxy", socket_path}, env.all() as {string})
    os.exit(1)
  end

  -- Wait for socket to appear (up to 5s)
  local timeout = 50
  while timeout > 0 do
    local stat = cfs.stat(socket_path)
    if stat then break end
    time.sleep(0, 100000000)
    timeout = timeout - 1
  end

  if timeout == 0 then
    signal.kill(pid, spawn.SIGTERM)
    spawn.wait()
    cfs.rmrf(tmpdir)
    return nil, "proxy socket not ready"
  end

  return {
    enabled = true,
    socket_path = socket_path,
    proxy_pid = pid,
    tmpdir = tmpdir,
  }
end

-- Stop sandbox proxy and clean up.
local function stop_sandbox(ctx: SandboxCtx)
  if not ctx then return end
  if ctx.proxy_pid > 0 then
    signal.kill(ctx.proxy_pid, spawn.SIGTERM)
    spawn.wait()
  end
  if ctx.tmpdir then
    cfs.rmrf(ctx.tmpdir)
  end
end

-- Read stdin for passing to a sandboxed child.
-- Always returns a string (never nil).
local function prepare_child_stdin(): string
  local tty = require("cosmic.tty")
  if tty.isatty(0) then
    return ""
  end
  local ok, data = pcall(io.read, "*a")
  if ok and data and data ~= "" then
    return data
  end
  return ""
end

return {
  start_sandbox = start_sandbox,
  stop_sandbox = stop_sandbox,
  prepare_child_stdin = prepare_child_stdin,
  setup_git_env = setup_git_env,
  env_get = env_get,
  env_set = env_set,
  ah_exe = ah_exe,
}
