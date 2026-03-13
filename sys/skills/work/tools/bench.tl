-- bench.tl: run a benchmark command, parse METRIC lines from output
local child = require("cosmic.child")
local work = require("ah.work")

local running_processes: {integer: any} = {}

local function find_executable(name: string): string
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
  name = "bench",
  description = "Run a benchmark command and parse METRIC name=value lines from its output",
  system_prompt = "Use bench to run the benchmark command specified in work.md.\nThe command should output METRIC name=value lines on stdout.\nExample: METRIC time=1234\nAll METRIC lines are parsed; other output is captured but not parsed.\nReturns: exit code, duration, parsed metrics, and tail of output.",
  running_processes = running_processes,
  input_schema = {
    type = "object",
    properties = {
      command = {type = "string", description = "Benchmark command to run"},
      timeout = {type = "integer", description = "Timeout in seconds (default: 600)"},
    },
    required = {"command"},
  },
  execute = function(input: {string: any}): string, boolean, any
    local command = input.command as string
    if not command or command == "" then
      return "error: command is required", true
    end

    local timeout_sec = (input.timeout as integer) or 600

    local shell = find_executable(os.getenv("AH_SHELL") or "bash")
    local timeout_cmd = find_executable("timeout")

    local start_time = os.clock()
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

    local _, stdout, exit_str = handle:read()
    local duration = os.clock() - start_time

    if pid then
      running_processes[pid] = nil
    end

    local stdout_str = (stdout as string) or ""
    local exit_code = tonumber(exit_str) as integer or 0

    -- Parse metrics from output
    local metrics = work.parse_metrics(stdout_str)

    -- Build result
    local parts: {string} = {}

    -- Duration
    table.insert(parts, string.format("duration: %.1fs", duration))

    -- Exit status
    if exit_code == 124 then
      table.insert(parts, "status: timeout (after " .. timeout_sec .. "s)")
    elseif exit_code ~= 0 then
      table.insert(parts, "status: failed (exit code " .. tostring(exit_code) .. ")")
    else
      table.insert(parts, "status: ok")
    end

    -- Metrics
    if next(metrics) then
      table.insert(parts, "")
      table.insert(parts, "metrics:")
      -- Sort metric names for stable output
      local names: {string} = {}
      for k in pairs(metrics) do
        table.insert(names, k)
      end
      table.sort(names)
      for _, name in ipairs(names) do
        table.insert(parts, "  " .. name .. " = " .. tostring(metrics[name]))
      end
    else
      table.insert(parts, "")
      table.insert(parts, "warning: no METRIC lines found in output")
      table.insert(parts, "expected format: METRIC name=value")
    end

    -- Tail of output (last 50 lines, excluding METRIC lines)
    local output_lines: {string} = {}
    for line in stdout_str:gmatch("[^\n]+") do
      if not line:match("^METRIC%s+") then
        table.insert(output_lines, line)
      end
    end
    if #output_lines > 0 then
      local start = math.max(1, #output_lines - 49)
      table.insert(parts, "")
      if start > 1 then
        table.insert(parts, "output (last " .. (#output_lines - start + 1) .. " of " .. #output_lines .. " lines):")
      else
        table.insert(parts, "output:")
      end
      for i = start, #output_lines do
        table.insert(parts, output_lines[i])
      end
    end

    local result = table.concat(parts, "\n")
    local is_error = exit_code ~= 0

    return result, is_error, {
      command = command,
      exit_code = exit_code,
      duration = duration,
      metrics = metrics,
      timed_out = exit_code == 124,
    }
  end,
}
