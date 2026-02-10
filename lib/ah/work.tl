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

local function run(cmd: {string}): boolean, string, integer
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
  return ok and exit_code == 0, stdout, exit_code
end

-- Run an ah agent subprocess inside the network sandbox.
-- Only api.anthropic.com is reachable; filesystem is restricted via pledge/unveil.
-- The sandbox is started and stopped around each agent invocation so that
-- only agent actions run inside the sandbox; all other (deterministic) work
-- executes without network isolation overhead.
local function sandboxed_agent(no_sandbox: boolean, prompt: string, db: string): boolean, string, integer
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
  end

  local handle, spawn_err = spawn.spawn(
    {ah_exe(), "-n", "--db", db, prompt},
    {env = run_env as {string}}
  )
  if not handle then
    if ctx then
      io.stderr:write("[sandbox] stopping proxy\n")
      stop_sandbox(ctx)
    end
    return false, spawn_err as string, -1
  end
  local ok, stdout, exit_str = handle:read()
  local exit_code = (tonumber(exit_str) or 0) as integer

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
  local ok, stdout = run({"gh", "issue", "comment", issue_url, "--body", body})
  if not ok then return false, "gh issue comment failed: " .. (stdout or "no output") end
  return true
end

local function execute_create_pr(branch: string, title: string, body: string): boolean, string
  local valid, verr = validate_branch(branch)
  if not valid then return false, verr end
  if not title then return false, "missing title" end
  if not body then return false, "missing body" end
  local ok, stdout = run({"gh", "pr", "create", "--head", branch, "--title", title, "--body", body})
  if not ok then return false, "gh pr create failed: " .. (stdout or "no output") end
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

-- Phase runners

local function phase_plan(no_sandbox: boolean, repo: string, issue_number: integer): integer, Issue
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

  prompt = prompt:gsub("{title}", issue.title)
  prompt = prompt:gsub("{body}", issue.body or "")
  prompt = prompt:gsub("{issue_number}", tostring(issue.number))

  local ok = sandboxed_agent(no_sandbox, prompt, "o/work/plan/session.db")

  if not ok then
    io.stderr:write("error: plan agent failed\n")
    return 1
  end

  if not read_file("o/work/plan/plan.md") then
    io.stderr:write("error: plan.md not created\n")
    return 1
  end

  return 0, issue
end

local function phase_do(no_sandbox: boolean, title: string, number: string): integer
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

  prompt = prompt:gsub("{title}", title)
  prompt = prompt:gsub("{plan.md contents}", plan_contents)
  prompt = prompt:gsub("{branch}", branch)

  local ok = sandboxed_agent(no_sandbox, prompt, "o/work/do/session.db")

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

  run({"git", "push", "-u", "origin", "HEAD:" .. branch})

  return 0
end

local function phase_check(no_sandbox: boolean): integer
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

  prompt = prompt:gsub("{plan.md contents}", plan_contents)
  prompt = prompt:gsub("{do.md contents}", do_contents)

  local ok = sandboxed_agent(no_sandbox, prompt, "o/work/check/session.db")

  if not ok then
    io.stderr:write("error: check agent failed\n")
    return 1
  end

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
]])
end

local function cmd_plan(no_sandbox: boolean, args: {string}): integer
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

  local rc = phase_plan(no_sandbox, repo, issue_number)
  return rc
end

local function cmd_do(no_sandbox: boolean, args: {string}): integer
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

  return phase_do(no_sandbox, title, number)
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
  -- Parse global options first (--no-sandbox, --help)
  local no_sandbox = false
  local filtered_args: {string} = {}

  for _, a in ipairs(args) do
    if a == "--no-sandbox" then
      no_sandbox = true
    elseif a == "-h" or a == "--help" then
      usage()
      return 0
    else
      table.insert(filtered_args, a)
    end
  end

  local subcmd = filtered_args[1]

  if subcmd == "plan" then
    return cmd_plan(no_sandbox, slice(filtered_args, 2))
  elseif subcmd == "do" then
    return cmd_do(no_sandbox, slice(filtered_args, 2))
  elseif subcmd == "check" then
    return phase_check(no_sandbox)
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
  }

  local parser = getopt.new(filtered_args, "hr:i:p:", longopts)

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

  -- Phase 1: Plan (agent — sandboxed)
  io.stderr:write("==> plan\n")
  local issue_num: integer = nil
  if issue_number then
    issue_num = tonumber(issue_number) as integer
  end
  local rc: integer
  local issue: Issue
  rc, issue = phase_plan(no_sandbox, repo, issue_num)
  if rc ~= 0 then return rc end

  if not issue then
    io.stderr:write("no issues to work on\n")
    return 0
  end

  -- Phase 2: Do (agent — sandboxed)
  io.stderr:write("==> do\n")
  rc = phase_do(no_sandbox, issue.title, tostring(issue.number))
  if rc ~= 0 then return rc end

  -- Phase 3: Push (deterministic — unsandboxed)
  io.stderr:write("==> push\n")
  rc = phase_push()
  if rc ~= 0 then return rc end

  -- Phase 4: Check (agent — sandboxed)
  io.stderr:write("==> check\n")
  rc = phase_check(no_sandbox)
  if rc ~= 0 then return rc end

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
}
