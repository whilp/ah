-- sys/tools/bash.tl: bash command execution tool
local child = require("cosmic.child")

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

return {
  name = "bash",
  description = "Execute a bash command",
  system_prompt = "Use bash for system commands, not for file operations.\nAll tools run in the working directory. Use relative paths for project files.\nFor multi-step commands, chain them with && on a single line or use \\\\ line continuations for readability.",
  running_processes = running_processes,
  input_schema = {
    type = "object",
    properties = {
      command = {type = "string", description = "Command to execute"},
      timeout = {type = "integer", description = "Timeout in milliseconds (default: 120000)"},
    },
    required = {"command"},
  },
  execute = function(input: {string: any}): string, boolean, any
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

    local ok, stdout, exit_str = handle:read()

    if pid then
      running_processes[pid] = nil
    end

    local stdout_str = (stdout as string) or ""
    local exit_code = tonumber(exit_str) as integer or 0

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
  end,
}
