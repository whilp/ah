-- ah/work/sandbox.tl: sandbox management, agent spawning, and limits
local spawn = require("cosmic.child")
local env = require("cosmic.env")
local fetch = require("cosmic.fetch")
local unix = require("cosmo.unix")
local util = require("ah.work.util")

-- Sandbox context for network isolation
local record SandboxCtx
  enabled: boolean
  socket_path: string
  proxy_pid: number
  tmpdir: string
end

local record AgentLimits
  max_tokens: integer   -- token budget passed via --max-tokens
  timeout_sec: integer  -- wall-clock timeout via timeout(1) wrapper
end

-- Overall deadline for unified work run (seconds)
local overall_timeout_sec = 1200  -- 20 minutes

-- Per-phase limits
local plan_limits: AgentLimits  = {max_tokens = 50000,  timeout_sec = 180}
local do_limits: AgentLimits    = {max_tokens = 100000, timeout_sec = 300}
local check_limits: AgentLimits = {max_tokens = 50000,  timeout_sec = 180}
local fix_limits: AgentLimits   = {max_tokens = 100000, timeout_sec = 300}
local friction_limits: AgentLimits = {max_tokens = 10000, timeout_sec = 60}

-- Start sandbox proxy
-- Returns sandbox context or nil on error
local function start_sandbox(): SandboxCtx, string
  util.log("starting sandbox...")
  -- Create temp directory for socket
  local tmpdir = unix.mkdtemp("/tmp/ah-sandbox-XXXXXX")
  if not tmpdir then
    util.log("failed to create temp directory for sandbox")
    return nil, "failed to create temp directory"
  end
  util.log("sandbox tmpdir: " .. tmpdir)

  local socket_path = tmpdir .. "/proxy.sock"

  -- Fork and exec proxy
  local exe = util.ah_exe()
  util.log("forking proxy: " .. exe .. " proxy " .. socket_path)
  local pid = unix.fork()
  if pid < 0 then
    util.log("fork failed")
    unix.rmrf(tmpdir)
    return nil, "fork failed"
  end

  if pid == 0 then
    -- Child: exec proxy
    unix.execve(exe, {exe, "proxy", socket_path}, env.all() as {string})
    os.exit(1)  -- exec failed
  end

  util.log("proxy forked with pid: " .. tostring(pid))

  -- Parent: wait for socket to appear
  local timeout = 50  -- 5 seconds (50 * 100ms)
  while timeout > 0 do
    local stat = unix.stat(socket_path)
    if stat then
      break
    end
    unix.nanosleep(0, 100000000)  -- 100ms
    timeout = timeout - 1
  end

  if timeout == 0 then
    util.log("proxy socket not ready after 5s, killing pid " .. tostring(pid))
    unix.kill(pid, unix.SIGTERM)
    unix.wait()
    unix.rmrf(tmpdir)
    return nil, "proxy socket not ready"
  end

  util.log("sandbox ready, socket: " .. socket_path)
  return {
    enabled = true,
    socket_path = socket_path,
    proxy_pid = pid,
    tmpdir = tmpdir,
  }
end

-- Stop sandbox proxy and clean up
local function stop_sandbox(ctx: SandboxCtx)
  if not ctx then return end
  if ctx.proxy_pid > 0 then
    unix.kill(ctx.proxy_pid, unix.SIGTERM)
    unix.wait()
  end
  if ctx.tmpdir then
    unix.rmrf(ctx.tmpdir)
  end
end

-- Build the argv for an agent subprocess.
-- Exported for testing.
local function build_agent_args(exe: string, db: string, prompt: string, new_session: boolean, limits: AgentLimits, model: string): {string}
  local args: {string} = {}

  -- Wall-clock timeout wrapper
  if limits and limits.timeout_sec and limits.timeout_sec > 0 then
    table.insert(args, "timeout")
    table.insert(args, tostring(limits.timeout_sec))
  end

  table.insert(args, exe)

  if new_session then
    table.insert(args, "-n")
  end

  -- Model selection
  if model then
    table.insert(args, "-m")
    table.insert(args, model)
  end

  -- Token budget
  if limits and limits.max_tokens and limits.max_tokens > 0 then
    table.insert(args, "--max-tokens")
    table.insert(args, tostring(limits.max_tokens))
  end

  table.insert(args, "--db")
  table.insert(args, db)
  table.insert(args, prompt)

  return args
end

-- Spawn an ah agent subprocess and wait for completion.
-- When new_session is true, passes -n to start a fresh session.
-- When false, continues the most recent session in the db.
local function spawn_agent(run_env: {string:string}, db: string, prompt: string, new_session: boolean, limits: AgentLimits, model: string): boolean, string, integer
  local args = build_agent_args(util.ah_exe(), db, prompt, new_session, limits, model)

  util.log("spawning agent: db=" .. db .. " prompt_len=" .. #prompt .. " new=" .. tostring(new_session))
  local handle, spawn_err = spawn.spawn(args, {env = run_env as {string}})
  if not handle then
    return false, spawn_err as string, -1
  end
  local stderr_out = handle.stderr:read()
  local ok, stdout, exit_str = handle:read()
  local exit_code = (tonumber(exit_str) or 0) as integer

  -- Detect timeout(1) exit code
  if exit_code == 124 then
    util.log("agent timed out (wall-clock limit)")
  end

  -- Log agent subprocess results for debugging
  util.log("agent exited: ok=" .. tostring(ok) .. " exit_code=" .. tostring(exit_code))
  if stderr_out and stderr_out ~= "" then
    local stderr_tail = stderr_out
    if #stderr_tail > 2000 then
      stderr_tail = "...(" .. #stderr_out .. " bytes total)\n" .. stderr_out:sub(-2000)
    end
    util.log("agent stderr:\n" .. stderr_tail)
  end
  if stdout and stdout ~= "" then
    local stdout_preview = stdout:sub(1, 500)
    if #stdout > 500 then stdout_preview = stdout_preview .. "..." end
    util.log("agent stdout: " .. stdout_preview)
  end

  return ok and exit_code == 0, stdout, exit_code
end

-- Run an ah agent subprocess inside the network sandbox.
-- Only api.anthropic.com is reachable; filesystem is restricted via pledge/unveil.
-- The sandbox is started and stopped around each agent invocation so that
-- only agent actions run inside the sandbox; all other (deterministic) work
-- executes without network isolation overhead.
-- If friction_prompt is provided, it is sent as a follow-up message in the
-- same session after the main prompt completes.
local function sandboxed_agent(no_sandbox: boolean, prompt: string, db: string, protect_dirs?: {string}, friction_prompt?: string, limits?: AgentLimits, model?: string): boolean, string, integer
  local ctx: SandboxCtx = nil
  if not no_sandbox then
    local sctx, err = start_sandbox()
    if not sctx then
      io.stderr:write("error: sandbox failed to start: " .. (err or "unknown") .. "\n")
      return false, "sandbox failed to start: " .. (err or "unknown"), 1
    end
    ctx = sctx
    io.stderr:write("[sandbox] proxy started on " .. ctx.socket_path .. "\n")
  end

  local run_env = env.all()
  util.setup_git_env(run_env)
  if ctx and ctx.enabled then
    local proxy_url, proxy_err = fetch.unix_proxy(ctx.socket_path)
    if not proxy_url then
      io.stderr:write("[sandbox] invalid proxy path: " .. (proxy_err or "unknown") .. "\n")
      stop_sandbox(ctx)
      return false, "invalid proxy path: " .. (proxy_err or "unknown"), 1
    end
    run_env.http_proxy = proxy_url
    run_env.HTTP_PROXY = proxy_url
    run_env.https_proxy = proxy_url
    run_env.HTTPS_PROXY = proxy_url
    run_env.AH_SANDBOX = "1"
    local protect = util.format_protect_dirs(protect_dirs)
    if protect then
      run_env.AH_PROTECT_DIRS = protect
    end
  end

  -- Main prompt: new session
  local ok, stdout, exit_code = spawn_agent(run_env, db, prompt, true, limits, model)

  if not ok then
    if ctx then
      io.stderr:write("[sandbox] stopping proxy\n")
      stop_sandbox(ctx)
    end
    return false, stdout, exit_code
  end

  -- Friction follow-up: same session (no -n)
  if friction_prompt then
    util.log("sending friction follow-up to same session")
    spawn_agent(run_env, db, friction_prompt, false, friction_limits, model)
  end

  if ctx then
    io.stderr:write("[sandbox] stopping proxy\n")
    stop_sandbox(ctx)
  end

  return ok and exit_code == 0, stdout, exit_code
end

return {
  overall_timeout_sec = overall_timeout_sec,
  plan_limits = plan_limits,
  do_limits = do_limits,
  check_limits = check_limits,
  fix_limits = fix_limits,
  friction_limits = friction_limits,
  sandboxed_agent = sandboxed_agent,
  build_agent_args = build_agent_args,
}
