-- ah/work.tl: single-iteration autonomous optimization
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local child = require("cosmic.child")
local db = require("ah.db")
local ulid = require("ulid")
local api = require("ah.api")
local tools = require("ah.tools")
local skills = require("ah.skills")
local loop = require("ah.loop")
local queue = require("ah.queue")
local prompt_mod = require("ah.prompt")
local cli_mod = require("ah.cli")

local WORK_SCHEMA = [[
create table if not exists work_iterations (
  id integer primary key autoincrement,
  status text not null,
  metric_value real,
  baseline_value real,
  message text,
  created_at integer not null
);
]]

local record Iteration
  status: string
  metric_value: number
  baseline_value: number
  message: string
end

-- Parse a single number from stdout. Returns nil if not a clean number.
local function parse_metric(stdout: string): number
  local trimmed = stdout:match("^%s*(.-)%s*$")
  if not trimmed or trimmed == "" then return nil end
  return tonumber(trimmed)
end

-- Run a shell script via cosmic.child. Returns stdout, stderr, exit_code.
local function run_script(path: string): string, string, integer
  local handle, err = child.spawn({"bash", path})
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

-- Initialize work tables in a session db.
local function init_work_db(d: db.DB)
  d._db:exec(WORK_SCHEMA)
end

-- Record an iteration outcome.
local function record_iteration(d: db.DB, iter: Iteration)
  d._db:exec([[
    insert into work_iterations (status, metric_value, baseline_value, message, created_at)
    values (?, ?, ?, ?, ?)
  ]], iter.status, iter.metric_value, iter.baseline_value, iter.message, os.time())
end

-- Get iteration count.
local function get_iteration_count(d: db.DB): integer
  for row in d._db:query("select count(*) as n from work_iterations") do
    return row.n as integer
  end
  return 0
end

-- Format recent iteration history for the agent prompt.
local function format_history(d: db.DB, n: integer): string
  local lines: {string} = {}
  for row in d._db:query("select status, metric_value, baseline_value, message from work_iterations order by id desc limit ?", n) do
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

-- Run an agent in a throwaway session. Returns last assistant text.
-- If quiet is true, suppress terminal output.
local function run_agent_once(
    cwd: string, system: string, model: string,
    prompt: string, quiet: boolean
  ): string
  local ah_dir = fs.join(cwd, ".ah")
  local id = ulid.generate()
  local dbpath = fs.join(ah_dir, id .. ".db")
  local d, derr = db.open(dbpath)
  if not d then
    io.stderr:write("work: db error: " .. (derr or "") .. "\n")
    return nil
  end
  local qpath = dbpath:gsub("%.db$", ".queue.db")
  local qdb, qerr = queue.open(qpath)
  if not qdb then
    io.stderr:write("work: queue error: " .. (qerr or "") .. "\n")
    db.close(d)
    return nil
  end
  local on_event = quiet and function(_: any) end or cli_mod.make_cli_handler("work", id)
  local opts: loop.AgentOpts = {max_tokens = 16384}
  loop.run_agent(d, qdb, system, model, prompt, nil, on_event, opts)
  local last_text: string = nil
  local last = db.get_last_message(d)
  if last and last.role == "assistant" then
    local blocks = db.get_content_blocks(d, last.id)
    for _, block in ipairs(blocks) do
      if block.block_type == "text" and block.content then
        last_text = block.content as string
      end
    end
  end
  queue.close(qdb)
  db.close(d)
  os.remove(dbpath)
  os.remove(qpath)
  return last_text or ""
end

-- Check if working tree has changes.
local function git_has_changes(): boolean
  return git("diff", "--quiet", "HEAD") == nil
end

-- Get diff excluding .ah/ directory.
local function git_diff(): string
  return git("diff", "HEAD", "--", ".", ":(exclude).ah") or ""
end

-- Revert working tree.
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

-- Build system prompt with tools and optional skill.
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
    d: db.DB, cwd: string, work_script: string,
    prompt: string, model: string
  ): integer
  init_work_db(d)
  local system = build_system(cwd)
  local effective_model = api.resolve_model(model or os.getenv("AH_MODEL"))
  local iter_num = get_iteration_count(d) + 1

  -- Get or establish baseline metric
  local best_str = db.get_context(d, "work:best")
  local best = best_str and tonumber(best_str)
  if not best then
    io.write("work: benchmarking baseline...\n")
    local bl_stdout, bl_stderr, bl_code = run_script(work_script)
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
    db.set_context(d, "work:best", tostring(best))
    db.set_context(d, "work:baseline", tostring(best))
  end
  local baseline = tonumber(db.get_context(d, "work:baseline")) or best
  local from_baseline = best ~= baseline and " (baseline " .. string.format("%.4g", baseline) .. ", " .. fmt_pct(best, baseline) .. ")" or ""
  io.write(string.format("work: #%d best=%.4g%s\n", iter_num, best, from_baseline))

  -- Phase 1: agent implements a change
  local history = format_history(d, 15)
  local implement_prompt = string.format(
    "%s\n\ncurrent metric: %.4g (lower is better)\n\n## iteration history\n%s",
    prompt, best, history)

  local impl_result = run_agent_once(cwd, system, effective_model, implement_prompt, false)
  if not impl_result then return 1 end

  if not git_has_changes() then
    io.write("work: no changes\n")
    record_iteration(d, {
        status = "skip", baseline_value = best,
        message = "no changes made",
      } as Iteration)
    return 1
  end

  -- Phase 2: benchmark the change
  io.write("work: benchmarking...\n")
  local bm_stdout, bm_stderr, bm_code = run_script(work_script)
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

  -- Phase 3: decide keep or discard
  if new_value < best then
    -- Improved — ask agent for a commit message (quiet, no terminal output)
    local diff = git_diff()
    local msg_prompt = string.format(
      "write a one-line git commit message for this change.\nmetric: %.4g → %.4g (%s)\n\n```\n%s\n```\n\nrespond with only the commit message, nothing else.",
      best, new_value, pct, diff)
    local msg_system = "write a one-line git commit message. respond with only the message."
    local msg = run_agent_once(cwd, msg_system, effective_model, msg_prompt, true)
    if not msg or msg == "" then msg = string.format("%.4g → %.4g (%s)", best, new_value, pct) end
    -- Clean up: take first non-empty line
    msg = msg:match("^%s*(.-)%s*$") or msg
    msg = msg:match("^([^\n]+)") or msg
    git_commit(msg)
    db.set_context(d, "work:best", tostring(new_value))
    io.write(string.format("work: keep %.4g → %.4g (%s) — %s\n", best, new_value, pct, msg))
    record_iteration(d, {
        status = "keep", metric_value = new_value,
        baseline_value = best, message = msg,
      } as Iteration)
    return 0
  else
    -- Not improved — discard directly, no agent call
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
  init_work_db = init_work_db,
  format_history = format_history,
}
