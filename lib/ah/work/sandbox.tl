-- ah/work/sandbox.tl: sandbox management and phase runner
local spawn = require("cosmic.child")
local env = require("cosmic.env")
local cfs = require("cosmic.fs")
local time = require("cosmic.time")
local proc = require("cosmic.proc")
local signal = require("cosmic.signal")
local util = require("ah.work.util")

-- Type declarations for cosmic.child handles
local record StdinHandle
  write: function(StdinHandle, string)
  close: function(StdinHandle)
end

local record StderrHandle
  read: function(StderrHandle): string
end

local record ChildHandle
  stdin: StdinHandle
  stderr: StderrHandle
  read: function(ChildHandle): boolean, string, string
end

local record ChildMod
  spawn: function({string}, {string:any}): ChildHandle, string
end

local child = spawn as ChildMod

-- Sandbox context for network isolation
local record SandboxCtx
  enabled: boolean
  socket_path: string
  proxy_pid: number
  tmpdir: string
end

-- Phase options for run_phase()
local record PhaseOpts
  sandbox: boolean       -- pass --sandbox to ah
  timeout: integer       -- wall-clock timeout in seconds
  unveil_dirs: {string}  -- directories to --unveil as read-only
  db: string             -- session database path
  prompt: string         -- prompt text (piped via stdin)
  max_tokens: integer    -- token budget
  model: string          -- model alias
end

-- Start sandbox proxy
-- Returns sandbox context or nil on error
local function start_sandbox(): SandboxCtx, string
  util.log("starting sandbox...")
  -- Create temp directory for socket
  local tmpdir = cfs.mkdtemp("/tmp/ah-sandbox-XXXXXX")
  if not tmpdir then
    util.log("failed to create temp directory for sandbox")
    return nil, "failed to create temp directory"
  end
  util.log("sandbox tmpdir: " .. tmpdir)

  local socket_path = tmpdir .. "/proxy.sock"

  -- Fork and exec proxy
  local exe = util.ah_exe()
  util.log("forking proxy: " .. exe .. " proxy " .. socket_path)
  local pid = spawn.fork()
  if pid < 0 then
    util.log("fork failed")
    cfs.rmrf(tmpdir)
    return nil, "fork failed"
  end

  if pid == 0 then
    -- Child: exec proxy
    proc.execve(exe, {exe, "proxy", socket_path}, env.all() as {string})
    os.exit(1)  -- exec failed
  end

  util.log("proxy forked with pid: " .. tostring(pid))

  -- Parent: wait for socket to appear
  local timeout = 50  -- 5 seconds (50 * 100ms)
  while timeout > 0 do
    local stat = cfs.stat(socket_path)
    if stat then
      break
    end
    time.sleep(0, 100000000)  -- 100ms
    timeout = timeout - 1
  end

  if timeout == 0 then
    util.log("proxy socket not ready after 5s, killing pid " .. tostring(pid))
    signal.kill(pid, spawn.SIGTERM)
    spawn.wait()
    cfs.rmrf(tmpdir)
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
    signal.kill(ctx.proxy_pid, spawn.SIGTERM)
    spawn.wait()
  end
  if ctx.tmpdir then
    cfs.rmrf(ctx.tmpdir)
  end
end

-- Build the argv for a phase subprocess.
-- The prompt is NOT included in argv; it is piped via stdin.
-- Exported for testing.
local function build_phase_args(exe: string, opts: PhaseOpts): {string}
  local args: {string} = {}

  -- Wall-clock timeout wrapper
  if opts.timeout and opts.timeout > 0 then
    table.insert(args, "timeout")
    table.insert(args, tostring(opts.timeout))
  end

  table.insert(args, exe)

  -- Always new session for phase runs
  table.insert(args, "-n")

  -- Sandbox flag
  if opts.sandbox then
    table.insert(args, "--sandbox")
  end

  -- Model selection
  if opts.model then
    table.insert(args, "-m")
    table.insert(args, opts.model)
  end

  -- Token budget
  if opts.max_tokens and opts.max_tokens > 0 then
    table.insert(args, "--max-tokens")
    table.insert(args, tostring(opts.max_tokens))
  end

  -- Unveil dirs (read-only)
  if opts.unveil_dirs then
    for _, dir in ipairs(opts.unveil_dirs) do
      table.insert(args, "--unveil")
      table.insert(args, dir .. ":r")
    end
  end

  table.insert(args, "--db")
  table.insert(args, opts.db)

  -- No prompt arg; prompt comes on stdin

  return args
end

-- Run a work phase as a standalone ah subprocess.
-- Builds `ah --sandbox --timeout T --unveil DIR:r ... --db DB` and pipes
-- the prompt via stdin. Returns (ok, stdout, exit_code).
local function run_phase(opts: PhaseOpts): boolean, string, integer
  local args = build_phase_args(util.ah_exe(), opts)

  util.log("run_phase: " .. table.concat(args, " ") .. " (prompt_len=" .. #opts.prompt .. ")")

  local run_env: {string} = env.all() as {string}
  util.setup_git_env(run_env)

  -- Set TMPDIR to a local writable location if not already set.
  -- APE binaries (cosmic) need to extract to $TMPDIR/.ape-* on first run;
  -- in restricted environments (GitHub Actions), /tmp may not be writable.
  if not util.env_get(run_env, "TMPDIR") then
    local cwd = cfs.getcwd() or "."
    local local_tmp = cwd .. "/o/tmp"
    cfs.mkdir(local_tmp, tonumber("755", 8))
    util.env_set(run_env, "TMPDIR", local_tmp)
  end

  local handle, spawn_err = child.spawn(args, {env = run_env})
  if not handle then
    return false, spawn_err as string, -1
  end

  -- Pipe prompt via stdin
  handle.stdin:write(opts.prompt)
  handle.stdin:close()

  local stderr_out = handle.stderr:read()
  local ok, stdout, exit_str = handle:read()
  local exit_code = (tonumber(exit_str) or 0) as integer

  -- Detect timeout(1) exit code
  if exit_code == 124 then
    util.log("phase timed out (wall-clock limit)")
  end

  -- Log subprocess results for debugging
  util.log("phase exited: ok=" .. tostring(ok) .. " exit_code=" .. tostring(exit_code))
  if stderr_out and stderr_out ~= "" then
    local stderr_tail = stderr_out
    if #stderr_tail > 2000 then
      stderr_tail = "...(" .. #stderr_out .. " bytes total)\n" .. stderr_out:sub(-2000)
    end
    util.log("phase stderr:\n" .. stderr_tail)
  end
  if stdout and stdout ~= "" then
    local stdout_preview = stdout:sub(1, 500)
    if #stdout > 500 then stdout_preview = stdout_preview .. "..." end
    util.log("phase stdout: " .. stdout_preview)
  end

  return ok and exit_code == 0, stdout, exit_code
end

-- Prepare stdin data for a sandboxed child process.
-- Reads all of stdin (when not a tty) and returns a string suitable for
-- passing to child.spawn({stdin = ...}).
-- IMPORTANT: always returns a string (never nil). Passing nil to
-- child.spawn creates a pipe that is never closed, causing the child
-- to block forever on io.read.
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
  run_phase = run_phase,
  build_phase_args = build_phase_args,
  start_sandbox = start_sandbox,
  stop_sandbox = stop_sandbox,
  prepare_child_stdin = prepare_child_stdin,
}
