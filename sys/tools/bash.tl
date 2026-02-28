-- sys/tools/bash.tl: bash command execution tool
local child = require("cosmic.child")
local unix = require("cosmo.unix")

-- Track running process handles for abort cleanup.
-- Exported as .running_processes so tools.tl can abort them.
local running_processes: {integer: any} = {}

-- Find executable in PATH or common locations
local function find_executable(name: string): string
  local env_override = os.getenv("AH_" .. name:upper())
  if env_override then
    return env_override
  end

  local common_paths: {string} = {
    "/usr/bin/" .. name,
    "/bin/" .. name,
    "/usr/local/bin/" .. name,
  }

  for _, path in ipairs(common_paths) do
    local f = io.open(path, "r")
    if f then
      f:close()
      return path
    end
  end

  return name
end

-- Reference the global interrupted flag
global interrupted: boolean

-- The tool table, declared early so execute can reference tool.on_output
local tool: {string: any} = {}

-- Close a pipe fd safely
local function close_pipe(pipe: any)
  local p = pipe as {string: any}
  if p and p.fd then
    pcall(unix.close, p.fd as number)
    p.fd = nil
  end
end

-- Poll-based incremental read from child process stdout and stderr.
-- Calls tool.on_output callback for each chunk as it arrives.
-- Returns the full combined output string.
local function read_incremental(handle: any): string
  local h = handle as {string: any}
  local stdout_pipe = h.stdout as {string: any}
  local stderr_pipe = h.stderr as {string: any}

  -- Close stdin so child doesn't block waiting for input
  close_pipe(h.stdin)

  local stdout_fd = stdout_pipe.fd as number
  local stderr_fd = stderr_pipe.fd as number

  local POLLIN = unix.POLLIN as number
  local chunks: {string} = {}
  -- Track which fds are still open
  local stdout_open = stdout_fd ~= nil
  local stderr_open = stderr_fd ~= nil

  while stdout_open or stderr_open do
    if interrupted then break end

    -- Build poll set from open fds
    local poll_set: {number: number} = {}
    if stdout_open then poll_set[stdout_fd] = POLLIN end
    if stderr_open then poll_set[stderr_fd] = POLLIN end

    -- Poll with 500ms timeout to allow interrupt checks
    local result = unix.poll(poll_set, 500)
    if not result then break end

    if stdout_open then
      local revents = result[stdout_fd]
      if revents and revents > 0 then
        local data = unix.read(stdout_fd, 65536) as string
        if not data or #data == 0 then
          stdout_open = false
        else
          table.insert(chunks, data)
          local cb = tool.on_output as function(string)
          if cb then cb(data) end
        end
      end
    end

    if stderr_open then
      local revents = result[stderr_fd]
      if revents and revents > 0 then
        local data = unix.read(stderr_fd, 65536) as string
        if not data or #data == 0 then
          stderr_open = false
        else
          table.insert(chunks, data)
          local cb = tool.on_output as function(string)
          if cb then cb(data) end
        end
      end
    end
  end

  -- Close pipe fds
  close_pipe(stdout_pipe)
  close_pipe(stderr_pipe)

  return table.concat(chunks)
end

-- Wait for child exit and return exit code.
-- Uses unix.wait directly since we already drained stdout/stderr.
local function wait_child(pid: number): integer
  local wpid, status = unix.wait(pid)
  if not wpid or wpid <= 0 then return -1 end
  if (unix.WIFEXITED as function(number): boolean)(status) then
    return (unix.WEXITSTATUS as function(number): number)(status) as integer
  end
  if (unix.WIFSIGNALED as function(number): boolean)(status) then
    return (128 + (unix.WTERMSIG as function(number): number)(status)) as integer
  end
  return -1
end

tool.name = "bash"
tool.description = "Execute a bash command"
tool.system_prompt = "Use bash for system commands, not for file operations.\nAll tools run in the working directory. Use relative paths for project files."
tool.running_processes = running_processes
tool.input_schema = {
  type = "object",
  properties = {
    command = {type = "string", description = "Command to execute"},
    timeout = {type = "integer", description = "Timeout in milliseconds (default: 120000)"},
  },
  required = {"command"},
}
tool.execute = function(input: {string: any}): string, boolean, any
  local command = input.command as string
  if not command then
    return "error: command is required", true
  end

  local timeout_ms = (input.timeout as integer) or 120000
  local timeout_sec = math.ceil(timeout_ms / 1000)

  local shell = find_executable(os.getenv("AH_SHELL") or "bash")
  local timeout_cmd = find_executable("timeout")
  local handle, err = child.spawn(
    {timeout_cmd, tostring(timeout_sec), shell, "-c", command}
  )
  if not handle then
    return "error: failed to spawn: " .. tostring(err), true
  end

  local pid = (handle as {string: any}).pid as integer
  if pid then
    running_processes[pid] = handle
  end

  -- Read output incrementally, streaming to display via on_output callback
  local stdout_str = read_incremental(handle)

  -- Wait for child to exit
  local exit_code = wait_child(pid)

  if pid then
    running_processes[pid] = nil
  end

  local result_parts: {string} = {}
  if stdout_str ~= "" then
    table.insert(result_parts, stdout_str)
  end

  if exit_code == 124 then
    table.insert(result_parts, "error: command timed out after " .. timeout_sec .. "s")
  elseif exit_code ~= 0 then
    table.insert(result_parts, "exit code: " .. tostring(exit_code))
  end

  local result = table.concat(result_parts, "\n")
  if result == "" then
    result = "(no output)"
  end

  return result, exit_code ~= 0, {command = command, exit_code = exit_code}
end

return tool
