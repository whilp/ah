-- ah/work.tl: unified work command (PDCA loop)
local spawn = require("cosmic.child")
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local json = require("cosmic.json")
local env = require("cosmic.env")
local fetch = require("cosmic.fetch")
local getopt = require("cosmic.getopt")
local unix = require("cosmo.unix")


-- Sandbox context for network isolation
local record SandboxCtx
  enabled: boolean
  socket_path: string
  proxy_pid: number
  tmpdir: string
end

local record Label
  name: string
end

local record RawIssue
  number: integer
  title: string
  body: string
  url: string
  labels: {Label}
  createdAt: string
end

local record Issue
  number: integer
  title: string
  body: string
  url: string
end

local record ParsedActions
  verdict: string
  actions: {{string:any}}
  success: boolean
end

-- Helpers

local function log(msg: string)
  io.stderr:write("[work] " .. msg .. "\n")
end

local function read_file(path: string): string
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

-- Format a list of directories for AH_PROTECT_DIRS env var (colon-separated).
-- Returns nil when there are no directories to protect.
local function format_protect_dirs(dirs: {string}): string
  if not dirs or #dirs == 0 then return nil end
  return table.concat(dirs, ":")
end

local function write_file(path: string, content: string): boolean
  local f = io.open(path, "w")
  if not f then return false end
  f:write(content)
  f:close()
  return true
end

local function read_prompt(name: string): string
  return cio.slurp("/zip/embed/sys/work/" .. name)
      or cio.slurp("sys/work/" .. name)
end

local function read_prompt_template(name: string): string
  return cio.slurp("/zip/embed/sys/work/prompts/" .. name .. ".md")
      or cio.slurp("sys/work/prompts/" .. name .. ".md")
end

-- Interpolate template variables safely.
-- Uses function replacement to avoid gsub interpreting % in values as capture references.
local function interpolate_prompt(template: string, vars: {string:string}): string
  for key, value in pairs(vars) do
    template = template:gsub("{" .. key .. "}", function(): string return value end)
  end
  return template
end

-- Diagnostic: inspect plan directory and report what was (or wasn't) created.
-- Returns a human-readable message explaining why plan.md may be missing.
local function plan_diagnostic(plan_dir: string): string
  local parts: {string} = {}

  local plan = read_file(plan_dir .. "/plan.md")
  if plan then
    table.insert(parts, "plan.md found (" .. #plan .. " bytes)")
    return table.concat(parts, "; ")
  end

  table.insert(parts, "plan.md not found")

  local update = read_file(plan_dir .. "/update.md")
  if update then
    table.insert(parts, "update.md found (bail condition): " .. update:sub(1, 200))
  end

  local issue = read_file(plan_dir .. "/issue.json")
  if issue then
    table.insert(parts, "issue.json present")
  else
    table.insert(parts, "issue.json missing")
  end

  return table.concat(parts, "; ")
end

local function ah_exe(): string
  return arg and arg[-1] or "ah"
end

-- Start sandbox proxy
-- Returns sandbox context or nil on error
local function start_sandbox(): SandboxCtx, string
  log("starting sandbox...")
  -- Create temp directory for socket
  local tmpdir = unix.mkdtemp("/tmp/ah-sandbox-XXXXXX")
  if not tmpdir then
    log("failed to create temp directory for sandbox")
    return nil, "failed to create temp directory"
  end
  log("sandbox tmpdir: " .. tmpdir)

  local socket_path = tmpdir .. "/proxy.sock"

  -- Fork and exec proxy
  local exe = ah_exe()
  log("forking proxy: " .. exe .. " proxy " .. socket_path)
  local pid = unix.fork()
  if pid < 0 then
    log("fork failed")
    unix.rmrf(tmpdir)
    return nil, "fork failed"
  end

  if pid == 0 then
    -- Child: exec proxy
    unix.execve(exe, {exe, "proxy", socket_path}, env.all() as {string})
    os.exit(1)  -- exec failed
  end

  log("proxy forked with pid: " .. tostring(pid))

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
    log("proxy socket not ready after 5s, killing pid " .. tostring(pid))
    unix.kill(pid, unix.SIGTERM)
    unix.wait()
    unix.rmrf(tmpdir)
    return nil, "proxy socket not ready"
  end

  log("sandbox ready, socket: " .. socket_path)
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

local function run(cmd: {string}): boolean, string, integer, string
  log("exec: " .. table.concat(cmd, " "))
  local handle, spawn_err = spawn.spawn(cmd, {env = env.all() as {string}})
  if not handle then
    log("spawn failed: " .. (spawn_err or "unknown"))
    return false, spawn_err as string, -1
  end
  local stderr_out = handle.stderr:read()
  local ok, stdout, exit_str = handle:read()
  local exit_code = (tonumber(exit_str) or 0) as integer
  if not (ok and exit_code == 0) then
    log("command failed (exit " .. tostring(exit_code) .. ")")
    if stdout and stdout ~= "" then
      log("stdout: " .. stdout:sub(1, 500))
    end
    if stderr_out and stderr_out ~= "" then
      log("stderr: " .. stderr_out:sub(1, 1000))
    end
  end
  return ok and exit_code == 0, stdout, exit_code, stderr_out
end

local record AgentLimits
  max_tokens: integer   -- token budget passed via --max-tokens
  timeout_sec: integer  -- wall-clock timeout via timeout(1) wrapper
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
  local args = build_agent_args(ah_exe(), db, prompt, new_session, limits, model)

  log("spawning agent: db=" .. db .. " prompt_len=" .. #prompt .. " new=" .. tostring(new_session))
  local handle, spawn_err = spawn.spawn(args, {env = run_env as {string}})
  if not handle then
    return false, spawn_err as string, -1
  end
  local stderr_out = handle.stderr:read()
  local ok, stdout, exit_str = handle:read()
  local exit_code = (tonumber(exit_str) or 0) as integer

  -- Detect timeout(1) exit code
  if exit_code == 124 then
    log("agent timed out (wall-clock limit)")
  end

  -- Log agent subprocess results for debugging
  log("agent exited: ok=" .. tostring(ok) .. " exit_code=" .. tostring(exit_code))
  if stderr_out and stderr_out ~= "" then
    local stderr_tail = stderr_out
    if #stderr_tail > 2000 then
      stderr_tail = "...(" .. #stderr_out .. " bytes total)\n" .. stderr_out:sub(-2000)
    end
    log("agent stderr:\n" .. stderr_tail)
  end
  if stdout and stdout ~= "" then
    local stdout_preview = stdout:sub(1, 500)
    if #stdout > 500 then stdout_preview = stdout_preview .. "..." end
    log("agent stdout: " .. stdout_preview)
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
-- Overall deadline for unified work run (seconds)
local overall_timeout_sec = 1200  -- 20 minutes

local function now_sec(): number
  local s, ns = unix.clock_gettime(unix.CLOCK_MONOTONIC)
  return s + ns / 1e9
end

-- Per-phase limits
local plan_limits: AgentLimits  = {max_tokens = 50000,  timeout_sec = 180}
local do_limits: AgentLimits    = {max_tokens = 100000, timeout_sec = 300}
local check_limits: AgentLimits = {max_tokens = 50000,  timeout_sec = 180}
local fix_limits: AgentLimits   = {max_tokens = 100000, timeout_sec = 300}
local friction_limits: AgentLimits = {max_tokens = 10000, timeout_sec = 60}

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
    local protect = format_protect_dirs(protect_dirs)
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
    log("sending friction follow-up to same session")
    spawn_agent(run_env, db, friction_prompt, false, friction_limits, model)
  end

  if ctx then
    io.stderr:write("[sandbox] stopping proxy\n")
    stop_sandbox(ctx)
  end

  return ok and exit_code == 0, stdout, exit_code
end

local function tee(path: string, line: string)
  print(line)
  local f = io.open(path, "a")
  if f then
    f:write(line .. "\n")
    f:close()
  end
end

local function slice(t: {string}, from: integer): {string}
  local result: {string} = {}
  for i = from, #t do
    result[#result + 1] = t[i]
  end
  return result
end

-- Labels used throughout the PDCA workflow
local required_labels: {string} = {"todo", "doing", "done", "failed"}

local function ensure_labels(repo: string): boolean, string
  for _, label in ipairs(required_labels) do
    run({"gh", "label", "create", label, "--repo", repo, "--force"})
  end
  return true
end

-- Issue selection

local function get_priority(labels: {Label}): integer
  for _, label in ipairs(labels) do
    if label.name == "p0" then return 0 end
    if label.name == "p1" then return 1 end
    if label.name == "p2" then return 2 end
  end
  return 3
end

local function sort_issues(issues: {RawIssue})
  table.sort(issues, function(a: RawIssue, b: RawIssue): boolean
    local a_priority = get_priority(a.labels)
    local b_priority = get_priority(b.labels)
    if a_priority ~= b_priority then
      return a_priority < b_priority
    end
    return a.createdAt < b.createdAt
  end)
end

local function fetch_issues(repo: string): {RawIssue}, string
  local ok, stdout = run({
    "gh", "issue", "list",
    "--repo", repo,
    "--label", "todo",
    "--state", "open",
    "--json", "number,title,body,url,labels,createdAt",
    "--limit", "100"
  })
  if not ok then return nil, "gh issue list failed: " .. (stdout or "no output") end
  local success, issues = pcall(json.decode, stdout)
  if not success or type(issues) ~= "table" then
    return nil, "failed to parse JSON from gh issue list: " .. (stdout or ""):sub(1, 200)
  end
  return issues as {RawIssue}
end

local function select_issue(issues: {RawIssue}): Issue
  if #issues == 0 then return nil end
  sort_issues(issues)
  local s = issues[1]
  return {number = s.number, title = s.title, body = s.body, url = s.url}
end

local function fetch_issue(repo: string, issue_number: integer): Issue, string
  local ok, stdout = run({
    "gh", "issue", "view", tostring(issue_number),
    "--repo", repo,
    "--json", "number,title,body,url"
  })
  if not ok then return nil, "gh issue view failed: " .. (stdout or "no output") end
  local success, issue = pcall(json.decode, stdout)
  if not success or type(issue) ~= "table" then
    return nil, "failed to parse JSON from gh issue view: " .. (stdout or ""):sub(1, 200)
  end
  return issue as Issue
end

local function create_issue_from_prompt(repo: string, prompt_name: string): integer, string
  local body = read_prompt_template(prompt_name)
  if not body then
    return nil, "unknown prompt: " .. prompt_name
  end
  log("creating issue from prompt: " .. prompt_name .. " (body length: " .. #body .. ")")
  local ok, stdout = run({
    "gh", "issue", "create",
    "--repo", repo,
    "--title", "work: " .. prompt_name,
    "--body", body,
    "--label", "todo",
  })
  if not ok then
    return nil, "gh issue create failed: " .. (stdout or "no output")
  end
  local number = tonumber(stdout:match("/issues/(%d+)"))
  if not number then
    return nil, "failed to parse issue number from: " .. (stdout or ""):sub(1, 200)
  end
  return number as integer
end

local function transition_to_doing(issue_url: string)
  log("transitioning issue to doing: " .. issue_url)
  run({"gh", "issue", "edit", issue_url, "--remove-label", "todo", "--add-label", "doing"})
end

-- Prompt building for do/check phases
-- Extracted for testability.

local function build_do_prompt(template: string, title: string, plan_contents: string, branch: string): string
  return interpolate_prompt(template, {
    title = title,
    ["plan.md contents"] = plan_contents,
    branch = branch,
  })
end

local function build_check_prompt(template: string, plan_contents: string, do_contents: string): string
  return interpolate_prompt(template, {
    ["plan.md contents"] = plan_contents,
    ["do.md contents"] = do_contents,
  })
end

local function build_fix_prompt(template: string, title: string, plan_contents: string, check_contents: string, branch: string): string
  return interpolate_prompt(template, {
    title = title,
    ["plan.md contents"] = plan_contents,
    ["check.md contents"] = check_contents,
    branch = branch,
  })
end

local function build_friction_prompt(template: string, friction_path: string): string
  return interpolate_prompt(template, {
    friction_path = friction_path,
  })
end

-- Format error from a failed command, preferring stderr over stdout.
local function format_run_error(prefix: string, stdout: string, stderr: string): string
  local detail: string
  if stderr and stderr ~= "" then
    detail = stderr
  elseif stdout and stdout ~= "" then
    detail = stdout
  else
    detail = "no output"
  end
  return prefix .. ": " .. detail
end

-- Branch extraction

local function extract_branch(plan_contents: string, default_number: string): string
  return plan_contents:match("Branch: ([^\n]+)") or ("work/" .. default_number)
end

-- Actions

local function parse_actions(content: string): ParsedActions, string
  if not content then return nil, "no content" end
  local ok, data = pcall(json.decode, content)
  if not ok or type(data) ~= "table" then
    return nil, "invalid json"
  end
  local d = data as {string:any}
  return {
    verdict = (d.verdict or "unknown") as string,
    actions = (d.actions or {}) as {{string:any}},
    success = d.verdict == "pass"
  }
end

local function validate_branch(branch: string): boolean, string
  if not branch then return false, "missing branch" end
  if not (branch as string):match("^work/") then
    return false, "branch must start with work/"
  end
  return true
end

local function execute_comment_issue(issue_url: string, body: string): boolean, string
  if not body then return false, "missing body" end
  local ok, stdout, _, stderr = run({"gh", "issue", "comment", issue_url, "--body", body})
  if not ok then return false, format_run_error("gh issue comment failed", stdout, stderr) end
  return true
end

local function execute_create_pr(branch: string, title: string, body: string): boolean, string
  local valid, verr = validate_branch(branch)
  if not valid then return false, verr end
  if not title then return false, "missing title" end
  if not body then return false, "missing body" end
  local ok, stdout, _, stderr = run({"gh", "pr", "create", "--head", branch, "--title", title, "--body", body})
  if not ok then return false, format_run_error("gh pr create failed", stdout, stderr) end
  return true
end

local function execute_action(issue_url: string, action: {string:any}, log_fn: function(string)): boolean
  local action_type = (action.action or "unknown") as string
  log_fn("Executing: " .. action_type)

  if action_type == "comment_issue" then
    local ok, err = execute_comment_issue(issue_url, action.body as string)
    if not ok then
      log_fn("  Failed: " .. (err or "unknown error"))
      return false
    end
    log_fn("  Success")
    return true

  elseif action_type == "create_pr" then
    local ok, err = execute_create_pr(action.branch as string, action.title as string, action.body as string)
    if not ok then
      log_fn("  Failed: " .. (err or "unknown error"))
      return false
    end
    log_fn("  Success")
    return true

  else
    log_fn("  Skipped: unknown action type")
    return true
  end
end

local function update_labels(issue_url: string, success: boolean)
  log("updating labels for: " .. issue_url .. " (success: " .. tostring(success) .. ")")
  run({"gh", "issue", "edit", issue_url, "--remove-label", "doing"})
  if success then
    run({"gh", "issue", "edit", issue_url, "--add-label", "done"})
  else
    run({"gh", "issue", "edit", issue_url, "--add-label", "failed"})
  end
end

-- Build friction follow-up prompt for a given phase output directory.
local function make_friction_prompt(phase_dir: string): string
  local template = read_prompt("friction.md")
  if not template then return nil end
  return build_friction_prompt(template, phase_dir .. "/friction.md")
end

-- Phase runners

local function phase_plan(no_sandbox: boolean, repo: string, issue_number: integer, model: string): integer, Issue
  -- Select or fetch issue
  local issue: Issue
  local err: string
  if issue_number then
    issue, err = fetch_issue(repo, issue_number)
  else
    local issues: {RawIssue}
    issues, err = fetch_issues(repo)
    if issues then
      issue = select_issue(issues)
    end
  end

  if err then
    io.stderr:write("error: " .. err .. "\n")
    return 1
  end

  if not issue then
    return 0
  end

  transition_to_doing(issue.url)

  fs.makedirs("o/work/plan")
  write_file("o/work/plan/issue.json", json.encode(issue) .. "\n")

  local prompt = read_prompt("plan.md")
  if not prompt then
    io.stderr:write("error: could not read plan.md prompt\n")
    return 1
  end

  prompt = interpolate_prompt(prompt, {
    title = issue.title,
    body = issue.body or "",
    issue_number = tostring(issue.number),
  })

  log("plan prompt interpolated (" .. #prompt .. " bytes) for issue #" .. tostring(issue.number))

  local friction = make_friction_prompt("o/work/plan")
  local ok = sandboxed_agent(no_sandbox, prompt, "o/work/plan/session.db", nil, friction, plan_limits, model)

  if not ok then
    io.stderr:write("error: plan agent failed\n")
    local diag = plan_diagnostic("o/work/plan")
    log("plan diagnostic: " .. diag)
    return 1
  end

  if not read_file("o/work/plan/plan.md") then
    local diag = plan_diagnostic("o/work/plan")
    io.stderr:write("error: plan.md not created\n")
    log("plan diagnostic: " .. diag)
    return 1
  end

  return 0, issue
end

local function phase_do(no_sandbox: boolean, title: string, number: string, model: string): integer
  fs.makedirs("o/work/do")

  local plan_contents = read_file("o/work/plan/plan.md")
  if not plan_contents then
    io.stderr:write("error: could not read o/work/plan/plan.md\n")
    return 1
  end

  local prompt = read_prompt("do.md")
  if not prompt then
    io.stderr:write("error: could not read do.md prompt\n")
    return 1
  end

  local branch = extract_branch(plan_contents, number)

  prompt = build_do_prompt(prompt, title, plan_contents, branch)

  local friction = make_friction_prompt("o/work/do")
  local ok = sandboxed_agent(no_sandbox, prompt, "o/work/do/session.db", {"o/work/plan"}, friction, do_limits, model)

  if not ok then
    io.stderr:write("error: do agent failed\n")
    return 1
  end

  write_file("o/work/do/branch.txt", branch .. "\n")

  return 0
end

local function phase_push(): integer
  local branch_content = read_file("o/work/do/branch.txt")
  if not branch_content then
    io.stderr:write("error: could not read o/work/do/branch.txt\n")
    return 1
  end

  local branch = branch_content:gsub("%s+$", "")

  local has_parent = run({"git", "rev-parse", "--verify", "HEAD~1"})
  if not has_parent then
    return 0
  end

  local same = run({"git", "diff", "--quiet", "origin/main...HEAD"})
  if same then
    return 0
  end

  local push_ok = run({"git", "push", "-u", "origin", "HEAD:" .. branch})
  if not push_ok then
    io.stderr:write("error: git push failed for branch " .. branch .. "\n")
    return 1
  end

  return 0
end

local function phase_check(no_sandbox: boolean, model: string): integer
  fs.makedirs("o/work/check")

  local plan_contents = read_file("o/work/plan/plan.md")
  if not plan_contents then
    io.stderr:write("error: could not read o/work/plan/plan.md\n")
    return 1
  end

  local do_contents = read_file("o/work/do/do.md")
  if not do_contents then
    io.stderr:write("error: could not read o/work/do/do.md\n")
    return 1
  end

  local prompt = read_prompt("check.md")
  if not prompt then
    io.stderr:write("error: could not read check.md prompt\n")
    return 1
  end

  prompt = build_check_prompt(prompt, plan_contents, do_contents)

  local friction = make_friction_prompt("o/work/check")
  local ok = sandboxed_agent(no_sandbox, prompt, "o/work/check/session.db", {"o/work/plan", "o/work/do"}, friction, check_limits, model)

  if not ok then
    io.stderr:write("error: check agent failed\n")
    return 1
  end

  return 0
end

local function read_check_verdict(): string
  local content = read_file("o/work/check/actions.json")
  if not content then return nil end
  local ok, data = pcall(json.decode, content)
  if not ok or type(data) ~= "table" then return nil end
  return ((data as {string:any}).verdict or "unknown") as string
end

local function phase_fix(no_sandbox: boolean, title: string, number: string, model: string): integer
  fs.makedirs("o/work/do")

  local plan_contents = read_file("o/work/plan/plan.md")
  if not plan_contents then
    io.stderr:write("error: could not read o/work/plan/plan.md\n")
    return 1
  end

  local check_contents = read_file("o/work/check/check.md")
  if not check_contents then
    io.stderr:write("error: could not read o/work/check/check.md\n")
    return 1
  end

  local prompt = read_prompt("fix.md")
  if not prompt then
    io.stderr:write("error: could not read fix.md prompt\n")
    return 1
  end

  local branch = extract_branch(plan_contents, number)

  prompt = build_fix_prompt(prompt, title, plan_contents, check_contents, branch)

  local friction = make_friction_prompt("o/work/do")
  local ok = sandboxed_agent(no_sandbox, prompt, "o/work/do/session.db", {"o/work/plan"}, friction, fix_limits, model)

  if not ok then
    io.stderr:write("error: fix agent failed\n")
    return 1
  end

  write_file("o/work/do/branch.txt", branch .. "\n")

  return 0
end

local function phase_act(issue_url: string): integer
  fs.makedirs("o/work/act")

  local act_md = "o/work/act/act.md"
  write_file(act_md, "")

  tee(act_md, "# Act")

  local actions_content = read_file("o/work/check/actions.json")
  if not actions_content then
    tee(act_md, "No actions.json found")
    update_labels(issue_url, false)
    return 0
  end

  local ok, actions_data = pcall(json.decode, actions_content)
  if not ok or type(actions_data) ~= "table" then
    tee(act_md, "Failed to parse actions.json")
    update_labels(issue_url, false)
    return 1
  end

  local data = actions_data as {string:any}
  local verdict = (data.verdict or "unknown") as string
  tee(act_md, "Verdict: " .. verdict)
  tee(act_md, "")
  tee(act_md, "## Actions")

  local actions = (data.actions or {}) as {{string:any}}
  local all_succeeded = true
  for _, action in ipairs(actions) do
    local log_fn = function(msg: string) tee(act_md, msg) end
    local action_ok = execute_action(issue_url, action, log_fn)
    if not action_ok then all_succeeded = false end
  end

  local success = verdict == "pass" and all_succeeded
  write_file("o/work/act/results.json", json.encode({
    verdict = verdict,
    success = success
  }) .. "\n")

  update_labels(issue_url, success)

  return 0
end

-- CLI

local function usage()
  io.stderr:write([[usage: ah work [command] [options]

commands:
  (default)  run all phases: plan, do, push, check, act
  plan       select issue and create plan
  do         execute plan
  check      verify execution
  act        execute actions
  push       push work branch

options:
  -h, --help               show this help
  -r, --repo <owner/repo>  repository (required)
  -i, --issue <number>     issue number (optional)
  -p, --prompt <name>      create issue from prompt template
  -m, --model <alias>      model alias (sonnet, opus, haiku)
]])
end

local function cmd_plan(no_sandbox: boolean, args: {string}, model: string): integer
  local repo: string
  local issue_number: integer

  local longopts = {
    {name = "help", has_arg = "none", short = "h"},
    {name = "repo", has_arg = "required", short = "r"},
    {name = "issue", has_arg = "required", short = "i"},
  }

  local parser = getopt.new(args, "hr:i:", longopts)

  while true do
    local opt, optarg = parser:next()
    if not opt then break end
    if opt == "h" or opt == "help" then
      io.stderr:write("usage: ah work plan --repo <owner/repo> [--issue <number>]\n")
      return 0
    elseif opt == "r" or opt == "repo" then
      repo = optarg
    elseif opt == "i" or opt == "issue" then
      issue_number = tonumber(optarg) as integer
    elseif opt == "?" then
      io.stderr:write("usage: ah work plan --repo <owner/repo> [--issue <number>]\n")
      return 1
    end
  end

  if not repo then
    io.stderr:write("usage: ah work plan --repo <owner/repo> [--issue <number>]\n")
    return 1
  end

  local rc = phase_plan(no_sandbox, repo, issue_number, model)
  return rc
end

local function cmd_do(no_sandbox: boolean, args: {string}, model: string): integer
  local title: string
  local number: string

  local longopts = {
    {name = "help", has_arg = "none", short = "h"},
    {name = "title", has_arg = "required", short = "t"},
    {name = "number", has_arg = "required", short = "n"},
  }

  local parser = getopt.new(args, "ht:n:", longopts)

  while true do
    local opt, optarg = parser:next()
    if not opt then break end
    if opt == "h" or opt == "help" then
      io.stderr:write("usage: ah work do --title <title> --number <number>\n")
      return 0
    elseif opt == "t" or opt == "title" then
      title = optarg
    elseif opt == "n" or opt == "number" then
      number = optarg
    elseif opt == "?" then
      io.stderr:write("usage: ah work do --title <title> --number <number>\n")
      return 1
    end
  end

  if not title or not number then
    io.stderr:write("usage: ah work do --title <title> --number <number>\n")
    return 1
  end

  return phase_do(no_sandbox, title, number, model)
end

local function cmd_act(args: {string}): integer
  local issue_url: string

  local longopts = {
    {name = "help", has_arg = "none", short = "h"},
    {name = "issue-url", has_arg = "required"},
  }

  local parser = getopt.new(args, "h", longopts)

  while true do
    local opt, optarg = parser:next()
    if not opt then break end
    if opt == "h" or opt == "help" then
      io.stderr:write("usage: ah work act --issue-url <url>\n")
      return 0
    elseif opt == "issue-url" then
      issue_url = optarg
    elseif opt == "?" then
      io.stderr:write("usage: ah work act --issue-url <url>\n")
      return 1
    end
  end

  if not issue_url then
    io.stderr:write("usage: ah work act --issue-url <url>\n")
    return 1
  end

  return phase_act(issue_url)
end

local function main(args: {string}): integer
  -- Parse global options first (--no-sandbox, --model, --help)
  local no_sandbox = false
  local model: string = nil
  local filtered_args: {string} = {}

  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--no-sandbox" then
      no_sandbox = true
    elseif a == "-m" or a == "--model" then
      i = i + 1
      model = args[i]
    elseif a == "-h" or a == "--help" then
      usage()
      return 0
    else
      table.insert(filtered_args, a)
    end
    i = i + 1
  end

  local subcmd = filtered_args[1]

  if subcmd == "plan" then
    return cmd_plan(no_sandbox, slice(filtered_args, 2), model)
  elseif subcmd == "do" then
    return cmd_do(no_sandbox, slice(filtered_args, 2), model)
  elseif subcmd == "check" then
    return phase_check(no_sandbox, model)
  elseif subcmd == "act" then
    return cmd_act(slice(filtered_args, 2))
  elseif subcmd == "push" then
    return phase_push()
  end

  -- Unified mode: parse options, run all phases
  local repo: string
  local issue_number: string
  local prompt_name: string

  local longopts = {
    {name = "help", has_arg = "none", short = "h"},
    {name = "repo", has_arg = "required", short = "r"},
    {name = "issue", has_arg = "required", short = "i"},
    {name = "prompt", has_arg = "required", short = "p"},
    {name = "model", has_arg = "required", short = "m"},
  }

  local parser = getopt.new(filtered_args, "hr:i:p:m:", longopts)

  while true do
    local opt, optarg = parser:next()
    if not opt then break end
    if opt == "h" or opt == "help" then
      usage()
      return 0
    elseif opt == "r" or opt == "repo" then
      repo = optarg
    elseif opt == "i" or opt == "issue" then
      issue_number = optarg
    elseif opt == "p" or opt == "prompt" then
      prompt_name = optarg
    elseif opt == "m" or opt == "model" then
      model = optarg
    elseif opt == "?" then
      usage()
      return 1
    end
  end

  if not repo then
    usage()
    return 1
  end

  -- Ensure required labels exist in the repository
  ensure_labels(repo)

  -- Create issue from prompt template if specified
  if prompt_name then
    if issue_number then
      io.stderr:write("error: --prompt and --issue are mutually exclusive\n")
      return 1
    end
    local num, err = create_issue_from_prompt(repo, prompt_name)
    if not num then
      io.stderr:write("error: " .. (err or "unknown") .. "\n")
      return 1
    end
    issue_number = tostring(num)
    io.stderr:write("created issue #" .. issue_number .. " from prompt: " .. prompt_name .. "\n")
  end

  local start_time = now_sec()
  local deadline = start_time + overall_timeout_sec

  local function check_deadline(phase: string): boolean
    if now_sec() > deadline then
      io.stderr:write("error: overall timeout exceeded before " .. phase .. " phase\n")
      return false
    end
    return true
  end

  -- Phase 1: Plan (agent — sandboxed)
  io.stderr:write("==> plan\n")
  local issue_num: integer = nil
  if issue_number then
    issue_num = tonumber(issue_number) as integer
  end
  local rc: integer
  local issue: Issue
  rc, issue = phase_plan(no_sandbox, repo, issue_num, model)
  if rc ~= 0 then return rc end

  if not issue then
    io.stderr:write("no issues to work on\n")
    return 0
  end

  local max_fix_retries = 2
  local issue_number_str = tostring(issue.number)

  -- Phase 2: Do (agent — sandboxed)
  if not check_deadline("do") then return 1 end
  io.stderr:write("==> do\n")
  rc = phase_do(no_sandbox, issue.title, issue_number_str, model)
  if rc ~= 0 then return rc end

  -- Phase 3: Push (deterministic — unsandboxed)
  if not check_deadline("push") then return 1 end
  io.stderr:write("==> push\n")
  rc = phase_push()
  if rc ~= 0 then return rc end

  -- Phase 4: Check (agent — sandboxed)
  if not check_deadline("check") then return 1 end
  io.stderr:write("==> check\n")
  rc = phase_check(no_sandbox, model)
  if rc ~= 0 then return rc end

  -- Retry loop: if check returns needs-fixes, run fix/push/check
  for attempt = 1, max_fix_retries do
    local verdict = read_check_verdict()
    if verdict ~= "needs-fixes" then break end
    if not check_deadline("fix") then break end

    io.stderr:write("==> fix (attempt " .. tostring(attempt) .. "/" .. tostring(max_fix_retries) .. ")\n")
    rc = phase_fix(no_sandbox, issue.title, issue_number_str, model)
    if rc ~= 0 then break end

    if not check_deadline("push") then break end
    io.stderr:write("==> push\n")
    rc = phase_push()
    if rc ~= 0 then break end

    if not check_deadline("check") then break end
    io.stderr:write("==> check\n")
    rc = phase_check(no_sandbox, model)
    if rc ~= 0 then break end
  end

  -- Phase 5: Act (deterministic — unsandboxed)
  io.stderr:write("==> act\n")
  rc = phase_act(issue.url)
  if rc ~= 0 then return rc end

  return 0
end

return {
  main = main,
  -- exported for testing
  get_priority = get_priority,
  sort_issues = sort_issues,
  select_issue = select_issue,
  extract_branch = extract_branch,
  parse_actions = parse_actions,
  validate_branch = validate_branch,
  execute_action = execute_action,
  slice = slice,
  required_labels = required_labels,
  ensure_labels = ensure_labels,
  interpolate_prompt = interpolate_prompt,
  plan_diagnostic = plan_diagnostic,
  build_do_prompt = build_do_prompt,
  build_check_prompt = build_check_prompt,
  format_run_error = format_run_error,
  format_protect_dirs = format_protect_dirs,
  build_fix_prompt = build_fix_prompt,
  build_friction_prompt = build_friction_prompt,
  build_agent_args = build_agent_args,
}
