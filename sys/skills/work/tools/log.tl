-- log.tl: record experiment result, compare to baseline, git commit/revert
local child = require("cosmic.child")
local work = require("ah.work")

local JSONL_FILE = "work.jsonl"

local function run_cmd(cmd: string): string, integer
  local handle = child.spawn({"/bin/sh", "-c", cmd})
  if not handle then return "", 1 end
  local _, stdout, exit_str = handle:read()
  local stdout_s = (stdout as string) or ""
  local code = tonumber(exit_str) as integer or 0
  return stdout_s:gsub("%s+$", ""), code
end

return {
  name = "log",
  description = "Record an experiment result. keep = git commit, discard/crash = git revert working tree",
  system_prompt = "Use log after each bench run to record the result.\nStatus meanings:\n  keep    — metric improved, commit changes\n  discard — metric regressed or no change, revert working tree\n  crash   — benchmark crashed, revert working tree\nThe tool auto-commits on keep and auto-reverts on discard/crash.\nAlways include the primary metric value and a short description.\nPass secondary metrics if the bench command produced them.",
  input_schema = {
    type = "object",
    properties = {
      metric = {type = "number", description = "Primary metric value from bench output"},
      status = {type = "string", description = "keep, discard, or crash"},
      description = {type = "string", description = "Short description of what this experiment tried"},
      metrics = {
        type = "object",
        description = "Secondary metrics as {name: value} pairs",
      },
    },
    required = {"metric", "status", "description"},
  },
  execute = function(input: {string: any}): string, boolean, any
    local metric = input.metric as number
    local status = input.status as string
    local description = input.description as string
    local metrics_raw = input.metrics as {string: any} or {}

    if status ~= "keep" and status ~= "discard" and status ~= "crash" then
      return "error: status must be keep, discard, or crash", true
    end

    -- Convert secondary metrics
    local metrics: {string: number} = {}
    for k, v in pairs(metrics_raw) do
      local num = tonumber(v)
      if num then
        metrics[k] = num
      end
    end

    -- Load current state
    local state = work.load_state(JSONL_FILE)
    if not state.config then
      return "error: no work.jsonl config found. run init_experiment or create work.jsonl with a config line first.", true
    end

    -- Get baseline for comparison
    local baseline_metric: number = nil
    if #state.results > 0 then
      baseline_metric = state.results[1].metric
    end
    local best = work.best_result(state)

    -- Append result
    work.append_result(JSONL_FILE, {
      metric = metric,
      metrics = metrics,
      status = status,
      description = description,
      timestamp = os.time(),
    })

    -- Git action
    local git_msg = ""
    if status == "keep" then
      -- Auto-commit
      local commit_msg = "work: " .. description
      run_cmd("git add -A")
      local _, exit_code = run_cmd('git commit -m ' .. string.format("%q", commit_msg) .. ' --allow-empty')
      if exit_code == 0 then
        local sha = run_cmd("git rev-parse --short HEAD")
        git_msg = "committed: " .. sha
      else
        git_msg = "warning: git commit failed (exit " .. tostring(exit_code) .. ")"
      end
    else
      -- Revert working tree
      run_cmd("git checkout -- .")
      run_cmd("git clean -fd")
      git_msg = "reverted working tree"
    end

    -- Build response
    local parts: {string} = {}
    table.insert(parts, "run #" .. tostring(#state.results + 1) .. ": " .. status)
    table.insert(parts, "metric: " .. tostring(metric))
    table.insert(parts, "git: " .. git_msg)

    -- Comparison to baseline
    if baseline_metric then
      table.insert(parts, "")
      table.insert(parts, "vs baseline: " .. work.format_comparison(metric, baseline_metric, state.config.direction))
    end

    -- Comparison to previous best
    if best and best.metric ~= baseline_metric then
      table.insert(parts, "vs best: " .. work.format_comparison(metric, best.metric, state.config.direction))
    end

    -- Summary
    local updated_state = work.load_state(JSONL_FILE)
    table.insert(parts, "")
    table.insert(parts, work.format_summary(updated_state))

    return table.concat(parts, "\n"), false, {
      status = status,
      metric = metric,
      run_number = #state.results + 1,
    }
  end,
}
