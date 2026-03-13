-- work.tl: shared library for the work skill (metric parsing, state, comparison)
local json = require("cosmic.json")
local cio = require("cosmic.io")

local record work
  record Config
    name: string
    metric_name: string
    metric_unit: string
    direction: string -- "lower" | "higher"
  end

  record Result
    metric: number
    metrics: {string: number}
    status: string -- "keep" | "discard" | "crash"
    description: string
    timestamp: number
  end

  record State
    config: Config
    results: {Result}
  end
end

-- Parse METRIC name=value lines from command output.
-- Returns a map of metric names to numeric values.
-- If a metric name appears multiple times, the last value wins.
function work.parse_metrics(output: string): {string: number}
  local metrics: {string: number} = {}
  if not output or output == "" then
    return metrics
  end
  for line in output:gmatch("[^\n]+") do
    local name, value = line:match("^METRIC%s+(%S+)=([%d%.%-]+)$")
    if name and value then
      local num = tonumber(value)
      if num then
        metrics[name] = num
      end
    end
  end
  return metrics
end

-- Compare two metric values given a direction.
-- Returns true if current is strictly better than baseline.
function work.is_better(current: number, baseline: number, direction: string): boolean
  if direction == "higher" then
    return current > baseline
  end
  return current < baseline
end

-- Format a human-readable comparison between current and baseline.
function work.format_comparison(current: number, baseline: number, direction: string): string
  if current == baseline then
    return "no change (same as baseline)"
  end
  local diff = current - baseline
  local pct = (math.abs(diff) / math.abs(baseline)) * 100
  local pct_str = string.format("%.1f%%", pct)
  if work.is_better(current, baseline, direction) then
    return pct_str .. " better than baseline (" .. tostring(baseline) .. " → " .. tostring(current) .. ")"
  else
    return pct_str .. " worse than baseline (" .. tostring(baseline) .. " → " .. tostring(current) .. ")"
  end
end

-- Load state from a JSONL file.
-- Returns a State with config (from the last config line) and results array.
function work.load_state(path: string): work.State
  local state: work.State = {
    config = nil,
    results = {},
  }
  local content = cio.slurp(path)
  if not content or content == "" then
    return state
  end
  for line in content:gmatch("[^\n]+") do
    local ok, entry = pcall(json.decode, line) as (boolean, {string: any})
    if ok and entry then
      if entry.type == "config" then
        state.config = {
          name = entry.name as string or "",
          metric_name = entry.metric_name as string or "",
          metric_unit = entry.metric_unit as string or "",
          direction = entry.direction as string or "lower",
        }
      else
        local metrics_raw = entry.metrics as {string: any} or {}
        local metrics: {string: number} = {}
        for k, v in pairs(metrics_raw) do
          metrics[k] = v as number
        end
        table.insert(state.results, {
          metric = entry.metric as number or 0,
          metrics = metrics,
          status = entry.status as string or "keep",
          description = entry.description as string or "",
          timestamp = entry.timestamp as number or 0,
        })
      end
    end
  end
  return state
end

-- Append a config line to a JSONL file.
function work.append_config(path: string, config: work.Config)
  local line = json.encode({
    type = "config",
    name = config.name,
    metric_name = config.metric_name,
    metric_unit = config.metric_unit,
    direction = config.direction,
  })
  local f = io.open(path, "a")
  if f then
    f:write(line .. "\n")
    f:close()
  end
end

-- Append a result line to a JSONL file.
function work.append_result(path: string, result: work.Result)
  local entry: {string: any} = {
    metric = result.metric,
    metrics = result.metrics or {},
    status = result.status,
    description = result.description,
    timestamp = result.timestamp or os.time(),
  }
  local line = json.encode(entry)
  local f = io.open(path, "a")
  if f then
    f:write(line .. "\n")
    f:close()
  end
end

-- Find the best kept result from state.
-- Returns nil if no kept results exist.
function work.best_result(state: work.State): work.Result
  if not state.config then return nil end
  local direction = state.config.direction or "lower"
  local best: work.Result = nil
  for _, r in ipairs(state.results) do
    if r.status == "keep" then
      if best == nil or work.is_better(r.metric, best.metric, direction) then
        best = r
      end
    end
  end
  return best
end

-- Format a human-readable summary of experiment state.
function work.format_summary(state: work.State): string
  local total = #state.results
  if total == 0 then
    return "no experiments yet"
  end
  local kept = 0
  local discarded = 0
  local crashed = 0
  for _, r in ipairs(state.results) do
    if r.status == "keep" then kept = kept + 1
    elseif r.status == "discard" then discarded = discarded + 1
    elseif r.status == "crash" then crashed = crashed + 1
    end
  end

  local parts: {string} = {}
  table.insert(parts, tostring(total) .. " experiments: " .. tostring(kept) .. " kept")
  if discarded > 0 then
    table.insert(parts, tostring(discarded) .. " discarded")
  end
  if crashed > 0 then
    table.insert(parts, tostring(crashed) .. " crashed")
  end
  local summary = table.concat(parts, ", ")

  if state.config then
    local baseline = state.results[1]
    if baseline then
      summary = summary .. "\nbaseline: " .. tostring(baseline.metric) .. " " .. (state.config.metric_unit or "")
    end
    local best = work.best_result(state)
    if best then
      summary = summary .. "\nbest: " .. tostring(best.metric) .. " " .. (state.config.metric_unit or "")
      if baseline and baseline.metric ~= best.metric then
        summary = summary .. " (" .. work.format_comparison(best.metric, baseline.metric, state.config.direction) .. ")"
      end
    end
  end

  return summary
end

return work
