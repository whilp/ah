-- ah/work.tl: single-iteration autonomous optimization
local child = require("cosmic.child")
local cio = require("cosmic.io")
local db = require("ah.db")
local api = require("ah.api")
local tools = require("ah.tools")
local skills = require("ah.skills")
local loop = require("ah.loop")
local conversations = require("ah.conversations")
local prompt_mod = require("ah.prompt")
local cli_mod = require("ah.cli")
local ctime = require("cosmic.time")
local ulid = require("ulid")

-- Parse a single number from stdout. Returns nil if not a clean number.
local function parse_metric(stdout: string): number
  local trimmed = stdout:match("^%s*(.-)%s*$")
  if not trimmed or trimmed == "" then return nil end
  return tonumber(trimmed)
end

-- Run a shell script via cosmic.child. Returns stdout, stderr, exit_code.
local function run_script(path: string): string, string, integer
  local handle, err = child.spawn({path})
  if not handle then
    return "", err or "spawn failed", 1
  end
  local stderr = handle.stderr:read() or ""
  local ok, stdout_raw, exit_str = handle:read()
  local stdout = (stdout_raw as string) or ""
  local exit_code = (tonumber(exit_str) or 0) as integer
  if not ok or exit_code ~= 0 then
    return stdout, stderr, exit_code ~= 0 and exit_code or 1
  end
  return stdout, stderr, 0
end

-- Run a git command via cosmic.child. Returns stdout or nil.
local function git(...: string): string
  local argv: {string} = {"git"}
  for i = 1, select("#", ...) do
    argv[#argv + 1] = select(i, ...) as string
  end
  local handle = child.spawn(argv)
  if not handle then return nil end
  handle.stderr:read()
  local ok, stdout_raw = handle:read()
  if not ok then return nil end
  return (((stdout_raw as string) or ""):gsub("%s+$", ""))
end

-- Format a percentage change.
local function fmt_pct(new_val: number, baseline: number): string
  if not baseline or baseline == 0 then return "" end
  local pct = ((new_val - baseline) / math.abs(baseline)) * 100
  if pct > 0 then
    return string.format("+%.1f%%", pct)
  end
  return string.format("%.1f%%", pct)
end

local record Iteration
  status: string
  metric_value: number
  baseline_value: number
  message: string
end

-- Record an iteration outcome.
local function record_iteration(d: db.DB, iter: Iteration)
  d._db:exec([[
    insert into work_iterations (id, status, metric_value, baseline_value, message, created_at)
    values (?, ?, ?, ?, ?, ?)
  ]], ulid.generate(), iter.status, iter.metric_value, iter.baseline_value, iter.message, (ctime.now()))
end

-- Get baseline metric (first row by ULID order).
local function get_baseline(d: db.DB): number
  for row in d._db:query("select metric_value from work_iterations order by id asc limit 1") do
    return row.metric_value as number
  end
  return nil
end

-- Get best metric (minimum across first measurement and kept iterations).
local function get_best(d: db.DB): number
  for row in d._db:query("select min(metric_value) as v from work_iterations where status in ('baseline', 'keep')") do
    return row.v as number
  end
  return nil
end

-- Get iteration count (excludes the initial baseline measurement).
local function get_iteration_count(d: db.DB): integer
  local total = 0
  for row in d._db:query("select count(*) as n from work_iterations") do
    total = row.n as integer
  end
  return total > 0 and total - 1 or 0
end

-- Format recent iteration history for the agent prompt.
local function format_history(d: db.DB, n: integer): string
  local lines: {string} = {}
  -- Skip the first row (baseline measurement).
  for row in d._db:query("select status, metric_value, baseline_value, message from work_iterations where id != (select id from work_iterations order by id asc limit 1) order by id desc limit ?", n) do
    local s = row.status as string
    local v = row.metric_value as number
    local b = row.baseline_value as number
    local m = row.message as string or ""
    if v then
      table.insert(lines, 1, string.format("%-8s %.4g (was %.4g, %s) %s",
          s, v, b, fmt_pct(v, b), m))
    else
      table.insert(lines, 1, string.format("%-8s %s", s, m))
    end
  end
  if #lines == 0 then return "no previous iterations." end
  return table.concat(lines, "\n")
end

-- Check if working tree has changes.
local function git_has_changes(): boolean
  return git("diff", "--quiet", "HEAD") == nil
end

-- Get diff excluding .ah/ directory.
local function git_diff(): string
  return git("diff", "HEAD", "--", ".", ":(exclude).ah") or ""
end

-- Revert working tree to HEAD.
local function git_revert()
  git("checkout", "--", ".")
end

-- Commit all changes using a file for the commit message.
local function git_commit(msg: string)
  git("add", "-A")
  local tmpfile = os.tmpname()
  cio.barf(tmpfile, msg)
  git("commit", "--quiet", "--file", tmpfile)
  os.remove(tmpfile)
end

-- Build system prompt for work mode.
local function build_system(cwd: string): string
  local system = prompt_mod.load_system_prompt(cwd)
  tools.init_custom_tools(cwd)
  tools.remove_tool("bash")
  tools.load_tool("/zip/sys/tools/grep.tl")
  local tp = tools.format_tools_for_prompt()
  if tp ~= "" then system = system .. "\n\n" .. tp end
  local loaded = skills.load_skills(cwd)
  local sk = loaded["autowork"]
  if sk then
    local content = cio.slurp(sk.file_path) or ""
    local fm_end = content:find("\n%-%-%-\n", 4)
    if content:match("^%-%-%-\n") and fm_end then
      content = content:sub(fm_end + 5)
    end
    if content ~= "" then system = system .. "\n\n" .. content end
  end
  return system
end

-- Run one work iteration. Returns 0=keep, 1=discard/error.
local function run_work(
    d: db.DB, cwd: string, benchmark: string,
    prompt: string, model: string
  ): integer
  local system = build_system(cwd)
  local effective_model = api.resolve_model(model or os.getenv("AH_MODEL"))
  local iter_num = get_iteration_count(d) + 1

  -- Get or establish baseline metric.
  local best = get_best(d)
  if not best then
    io.write("work: benchmarking baseline...\n")
    local bl_stdout, bl_stderr, bl_code = run_script(benchmark)
    if bl_code ~= 0 then
      io.stderr:write("work: benchmark failed (exit " .. bl_code .. ")\n")
      io.stderr:write(bl_stderr)
      return 1
    end
    best = parse_metric(bl_stdout)
    if not best then
      io.stderr:write("work: benchmark did not print a number to stdout\n")
      if bl_stdout ~= "" then io.stderr:write("stdout: " .. bl_stdout .. "\n") end
      return 1
    end
    record_iteration(d, {
        status = "baseline", metric_value = best,
        baseline_value = best, message = "initial baseline",
      } as Iteration)
  end
  local baseline = get_baseline(d) or best
  local from_baseline = best ~= baseline and " (baseline " .. string.format("%.4g", baseline) .. ", " .. fmt_pct(best, baseline) .. ")" or ""
  io.write(string.format("work: #%d best=%.4g%s\n", iter_num, best, from_baseline))

  -- Phase 1: agent implements a change.
  local history = format_history(d, 15)
  local implement_prompt = string.format(
    "%s\n\ncurrent metric: %.4g (lower is better)\n\n## iteration history\n%s",
    prompt, best, history)

  local conv = conversations.create_conversation(d, {name = "work-" .. iter_num})
  local on_event = cli_mod.make_cli_handler("work", conv.id)
  local now = (ctime.now()) as number
  local agent_opts: loop.AgentOpts = {deadline = now + 300}
  loop.run_agent(d, conv.id, system, effective_model, implement_prompt, nil, on_event, agent_opts)
  conversations.close_conversation(d, conv.id)

  if not git_has_changes() then
    io.write("work: no changes\n")
    record_iteration(d, {
        status = "skip", baseline_value = best,
        message = "no changes made",
      } as Iteration)
    return 1
  end

  -- Phase 2: benchmark the change.
  io.write("work: benchmarking...\n")
  local bm_stdout, bm_stderr, bm_code = run_script(benchmark)
  if bm_code ~= 0 then
    io.write("work: benchmark crashed, reverting\n")
    io.stderr:write(bm_stderr)
    git_revert()
    record_iteration(d, {
        status = "crash", baseline_value = best,
        message = "benchmark failed",
      } as Iteration)
    return 1
  end
  local new_value = parse_metric(bm_stdout)
  if not new_value then
    io.write("work: benchmark produced no metric, reverting\n")
    git_revert()
    record_iteration(d, {
        status = "crash", baseline_value = best,
        message = "no metric output",
      } as Iteration)
    return 1
  end

  local pct = fmt_pct(new_value, best)

  -- Phase 3: decide keep or discard.
  if new_value < best then
    local diff = git_diff()
    local summary = diff:match("^(.-)\n") or "optimization"
    local msg = string.format("work: %.4g → %.4g (%s) %s", best, new_value, pct, summary)
    git_commit(msg)
    io.write(string.format("work: keep %.4g → %.4g (%s)\n", best, new_value, pct))
    record_iteration(d, {
        status = "keep", metric_value = new_value,
        baseline_value = best, message = msg,
      } as Iteration)
    return 0
  else
    git_revert()
    local msg = string.format("%.4g → %.4g (%s)", best, new_value, pct)
    io.write(string.format("work: discard %.4g → %.4g (%s)\n", best, new_value, pct))
    record_iteration(d, {
        status = "discard", metric_value = new_value,
        baseline_value = best, message = msg,
      } as Iteration)
    return 1
  end
end

return {
  run_work = run_work,
  parse_metric = parse_metric,
  run_script = run_script,
  fmt_pct = fmt_pct,
  format_history = format_history,
  get_best = get_best,
  get_baseline = get_baseline,
  git_revert = git_revert,
}
