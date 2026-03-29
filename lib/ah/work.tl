-- ah/work.tl: bisect-style optimization loop
--
-- ah work start BENCHMARK "goal"  — establish baseline
-- ah work run                     — one iteration: agent → benchmark → keep/discard
-- ah work log                     — print iteration history
-- ah work status                  — print current metric
-- ah work reset                   — clear work state
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

local record Iteration
  status: string
  metric_value: number
  baseline_value: number
  message: string
  conversation_id: string
end

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

-- Record an iteration outcome.
local function record_iteration(d: db.DB, iter: Iteration)
  d._db:exec([[
    insert into work_iterations (id, conversation_id, status, metric_value, baseline_value, message, created_at)
    values (?, ?, ?, ?, ?, ?, ?)
  ]], ulid.generate(), iter.conversation_id, iter.status, iter.metric_value, iter.baseline_value, iter.message, (ctime.now()))
end

-- Get baseline metric (first recorded measurement).
local function get_baseline(d: db.DB): number
  for row in d._db:query("select metric_value from work_iterations where status = 'baseline' order by created_at asc, id asc limit 1") do
    return row.metric_value as number
  end
  return nil
end

-- Get best metric (minimum among baseline and kept iterations).
local function get_best(d: db.DB): number
  for row in d._db:query("select min(metric_value) as v from work_iterations where status in ('baseline', 'keep')") do
    return row.v as number
  end
  return nil
end

-- Get iteration count (excluding baseline).
local function get_iteration_count(d: db.DB): integer
  for row in d._db:query("select count(*) as n from work_iterations where status != 'baseline'") do
    return row.n as integer
  end
  return 0
end

-- Format recent iteration history for the agent prompt.
local function format_history(d: db.DB, n: integer): string
  local lines: {string} = {}
  for row in d._db:query("select status, metric_value, baseline_value, message from work_iterations where status != 'baseline' order by created_at desc, id desc limit ?", n) do
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

-- Get a short diffstat summary suitable for commit messages.
local function git_diffstat(): string
  return git("diff", "--stat", "HEAD", "--", ".", ":(exclude).ah") or ""
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

-- Get the stored benchmark script path.
local function get_benchmark(d: db.DB): string
  return db.get_context(d, "work:benchmark")
end

-- Get the stored goal prompt.
local function get_goal(d: db.DB): string
  return db.get_context(d, "work:goal")
end

-- Build system prompt with tools and autowork skill.
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

-- "ah work start BENCHMARK GOAL" — run benchmark, record baseline.
local function cmd_start(d: db.DB, benchmark: string, goal: string): integer
  -- Check for existing work session.
  if get_baseline(d) then
    io.stderr:write("work: already started (use 'ah work reset' to clear)\n")
    return 1
  end

  -- Validate benchmark script exists and is executable.
  local stdout, stderr, code = run_script(benchmark)
  if code ~= 0 then
    io.stderr:write("work: benchmark failed (exit " .. code .. ")\n")
    io.stderr:write(stderr)
    return 1
  end
  local metric = parse_metric(stdout)
  if not metric then
    io.stderr:write("work: benchmark did not print a number to stdout\n")
    if stdout ~= "" then io.stderr:write("stdout: " .. stdout .. "\n") end
    return 1
  end

  -- Record baseline and config.
  record_iteration(d, {
      status = "baseline", metric_value = metric,
      baseline_value = metric, message = "initial baseline",
    } as Iteration)
  db.set_context(d, "work:benchmark", benchmark)
  db.set_context(d, "work:goal", goal)

  io.write(string.format("work: started — baseline %.4g\n", metric))
  return 0
end

-- "ah work run" — one agent iteration.
local function cmd_run(d: db.DB, cwd: string, model: string): integer
  local benchmark = get_benchmark(d)
  if not benchmark then
    io.stderr:write("work: not started (use 'ah work start BENCHMARK GOAL')\n")
    return 1
  end
  local goal = get_goal(d) or ""
  local best = get_best(d)
  if not best then
    io.stderr:write("work: no baseline (use 'ah work reset' and start again)\n")
    return 1
  end
  local baseline = get_baseline(d) or best

  local system = build_system(cwd)
  local effective_model = api.resolve_model(model or os.getenv("AH_MODEL"))
  local iter_num = get_iteration_count(d) + 1

  local from_baseline = best ~= baseline and " (baseline " .. string.format("%.4g", baseline) .. ", " .. fmt_pct(best, baseline) .. ")" or ""
  io.write(string.format("work: #%d best=%.4g%s\n", iter_num, best, from_baseline))

  -- Phase 1: agent implements a change.
  local history = format_history(d, 15)
  local implement_prompt = string.format(
    "%s\n\ncurrent metric: %.4g (lower is better)\n\n## iteration history\n%s",
    goal, best, history)

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
        message = "no changes made", conversation_id = conv.id,
      } as Iteration)
    return 1
  end

  -- Phase 2: benchmark the change.
  io.write("work: benchmarking...\n")
  local bm_stdout, bm_stderr, bm_code = run_script(benchmark)
  if bm_code ~= 0 then
    io.stderr:write("work: benchmark crashed (exit " .. bm_code .. "), reverting\n")
    io.stderr:write(bm_stderr)
    git_revert()
    record_iteration(d, {
        status = "crash", baseline_value = best,
        message = "benchmark exit " .. bm_code, conversation_id = conv.id,
      } as Iteration)
    return 1
  end

  local new_value = parse_metric(bm_stdout)
  if not new_value then
    io.stderr:write("work: no metric, reverting\n")
    git_revert()
    record_iteration(d, {
        status = "crash", baseline_value = best,
        message = "no metric output", conversation_id = conv.id,
      } as Iteration)
    return 1
  end

  local pct = fmt_pct(new_value, best)

  -- Phase 3: decide keep or discard.
  if new_value < best then
    local stat = git_diffstat()
    local summary = stat:match("^(.-)\n") or "optimization"
    local msg = string.format("%.4g → %.4g (%s) %s", best, new_value, pct, summary)
    git_commit("work: " .. msg)
    io.write(string.format("work: keep %.4g → %.4g (%s)\n", best, new_value, pct))
    record_iteration(d, {
        status = "keep", metric_value = new_value,
        baseline_value = best, message = msg, conversation_id = conv.id,
      } as Iteration)
    return 0
  else
    git_revert()
    local msg = string.format("%.4g → %.4g (%s)", best, new_value, pct)
    io.write(string.format("work: discard %.4g → %.4g (%s)\n", best, new_value, pct))
    record_iteration(d, {
        status = "discard", metric_value = new_value,
        baseline_value = best, message = msg, conversation_id = conv.id,
      } as Iteration)
    return 1
  end
end

-- "ah work log" — print iteration history.
local function cmd_log(d: db.DB): integer
  local baseline = get_baseline(d)
  if not baseline then
    io.stderr:write("work: not started\n")
    return 1
  end
  io.write(string.format("baseline: %.4g\n\n", baseline))
  for row in d._db:query("select status, metric_value, baseline_value, message, created_at from work_iterations where status != 'baseline' order by created_at asc, id asc") do
    local s = row.status as string
    local v = row.metric_value as number
    local b = row.baseline_value as number
    local m = row.message as string or ""
    if v then
      io.write(string.format("%-8s %.4g (was %.4g, %s) %s\n",
          s, v, b, fmt_pct(v, b), m))
    else
      io.write(string.format("%-8s %s\n", s, m))
    end
  end
  local best = get_best(d)
  if best and best ~= baseline then
    io.write(string.format("\nbest: %.4g (%s from baseline)\n", best, fmt_pct(best, baseline)))
  end
  return 0
end

-- "ah work status" — print current state.
local function cmd_status(d: db.DB): integer
  local baseline = get_baseline(d)
  if not baseline then
    io.stderr:write("work: not started\n")
    return 1
  end
  local best = get_best(d) or baseline
  local n = get_iteration_count(d)
  local benchmark = get_benchmark(d) or "(unknown)"
  local goal = get_goal(d) or "(none)"
  io.write(string.format("benchmark: %s\n", benchmark))
  io.write(string.format("goal:      %s\n", goal))
  io.write(string.format("baseline:  %.4g\n", baseline))
  io.write(string.format("best:      %.4g (%s)\n", best, fmt_pct(best, baseline)))
  io.write(string.format("iterations: %d\n", n))
  return 0
end

-- "ah work reset" — clear work state.
local function cmd_reset(d: db.DB): integer
  d._db:exec("delete from work_iterations")
  db.set_context(d, "work:benchmark", nil)
  db.set_context(d, "work:goal", nil)
  io.write("work: reset\n")
  return 0
end

-- Dispatch work subcommands. Called from init.tl.
local function cmd_work(d: db.DB, cwd: string, subcmd: string, args: {string}, model: string): integer
  if subcmd == "start" then
    local benchmark = args[1]
    if not benchmark then
      io.stderr:write("usage: ah work start BENCHMARK [GOAL...]\n")
      return 1
    end
    local goal_parts: {string} = {}
    for i = 2, #args do goal_parts[#goal_parts + 1] = args[i] end
    local goal = table.concat(goal_parts, " ")
    if goal == "" then
      io.stderr:write("usage: ah work start BENCHMARK GOAL\n")
      return 1
    end
    return cmd_start(d, benchmark, goal)
  elseif subcmd == "run" then
    return cmd_run(d, cwd, model)
  elseif subcmd == "log" then
    return cmd_log(d)
  elseif subcmd == "status" then
    return cmd_status(d)
  elseif subcmd == "reset" then
    return cmd_reset(d)
  else
    io.stderr:write("usage: ah work <start|run|log|status|reset>\n")
    return 1
  end
end

return {
  cmd_work = cmd_work,
  parse_metric = parse_metric,
  run_script = run_script,
  fmt_pct = fmt_pct,
  format_history = format_history,
  get_best = get_best,
  get_baseline = get_baseline,
  get_benchmark = get_benchmark,
  get_goal = get_goal,
  record_iteration = record_iteration,
  git_revert = git_revert,
}
