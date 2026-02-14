-- ah/work.tl: unified work command (PDCA loop)
--
-- Orchestrates phase runners and CLI dispatch.
-- Helpers live in ah.work.{util, issue, action, prompt, sandbox}.
local fs = require("cosmic.fs")
local json = require("cosmic.json")
local getopt = require("cosmic.getopt")
local unix = require("cosmo.unix")

-- Helper to create directory with error handling and verification
-- TODO: fix cosmic fs.makedirs to return (ok, err) instead of silent failure
-- see https://github.com/anthropics/cosmic/issues/XXX (file issue)
local function ensure_dir(path: string): boolean, string
  fs.makedirs(path)
  -- TODO: remove this stat workaround once cosmic fs.makedirs returns errors
  local stat = unix.stat(path)
  if not stat then
    return false, "failed to create directory: " .. path
  end
  return true, nil
end

-- Local record types for the orchestrator
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

local record AgentLimits
  max_tokens: integer
  timeout_sec: integer
end

-- Submodule interfaces
local record Util
  log: function(string)
  read_file: function(string): string
  write_file: function(string, string): boolean
  ah_exe: function(): string
  run: function({string}): boolean, string, integer, string
  tee: function(string, string)
  slice: function({string}, integer): {string}
  now_sec: function(): number
  extract_branch: function(string, string): string
  format_protect_dirs: function({string}): string
  format_run_error: function(string, string, string): string
  setup_git_env: function({string:string})
end

local record IssueMod
  get_priority: function({Label}): integer
  sort_issues: function({RawIssue})
  fetch_issues: function(string): {RawIssue}, string
  select_issue: function({RawIssue}): Issue
  fetch_issue: function(string, integer): Issue, string
  create_issue_from_prompt: function(string, string, function(string): string): integer, string
  transition_to_doing: function(string)
  update_labels: function(string, boolean)
  required_labels: {string}
  ensure_labels: function(string): boolean, string
end

local record ActionMod
  parse_actions: function(string): ParsedActions, string
  validate_branch: function(string): boolean, string
  issue_number_from_url: function(string): string
  build_pr_body: function(string, string): string
  execute_action: function(string, {string:any}, function(string)): boolean
end

local record ParsedActions
  verdict: string
  actions: {{string:any}}
  success: boolean
end

local record FrictionIssue
  title: string
  body: string
  labels: {string}
end

local record FrictionIssues
  issues: {FrictionIssue}
end

local record PromptMod
  read_prompt: function(string): string
  read_prompt_template: function(string): string
  interpolate_prompt: function(string, {string:string}): string
  plan_diagnostic: function(string): string
  build_do_prompt: function(string, string, string, string, string): string
  build_check_prompt: function(string, string, string): string
  build_fix_prompt: function(string, string, string, string, string, string): string
  build_friction_prompt: function(string, string): string
  build_plan_prompt: function(string, string, string, string): string
  make_friction_prompt: function(string): string
end

local record SandboxMod
  overall_timeout_sec: number
  plan_limits: AgentLimits
  do_limits: AgentLimits
  check_limits: AgentLimits
  fix_limits: AgentLimits
  friction_limits: AgentLimits
  sandboxed_agent: function(boolean, string, string, {string}, string, AgentLimits, string): boolean, string, integer
  build_agent_args: function(string, string, string, boolean, AgentLimits, string): {string}
end

local util = require("ah.work.util") as Util
local issue_mod = require("ah.work.issue") as IssueMod
local action = require("ah.work.action") as ActionMod
local prompt = require("ah.work.prompt") as PromptMod
local sandbox = require("ah.work.sandbox") as SandboxMod

local analyze_limits: AgentLimits = {max_tokens = 50000, timeout_sec = 180}

-- Friction issue parsing/validation

local function parse_friction_issues(content: string): FrictionIssues, string
  if not content then return nil, "no content" end
  local ok, data = pcall(json.decode, content)
  if not ok or type(data) ~= "table" then
    return nil, "invalid json"
  end
  local d = data as {string:any}
  local raw_issues = (d.issues or {}) as {{string:any}}
  local result: FrictionIssues = {issues = {}}
  for _, raw in ipairs(raw_issues) do
    table.insert(result.issues, {
      title = (raw.title or "") as string,
      body = (raw.body or "") as string,
      labels = (raw.labels or {}) as {string},
    })
  end
  return result
end

local function validate_friction_issue(issue: FrictionIssue): boolean, string
  if not issue.title or issue.title == "" then return false, "missing title" end
  if not issue.body or issue.body == "" then return false, "missing body" end
  if not issue.title:match("^friction: ") then return false, "title must start with 'friction: '" end
  return true
end

-- Phase runners

local function phase_plan(no_sandbox: boolean, repo: string, issue_number: integer, model: string): integer, Issue
  -- Select or fetch issue
  local issue: Issue
  local err: string
  if issue_number then
    issue, err = issue_mod.fetch_issue(repo, issue_number)
  else
    local issues: {RawIssue}
    issues, err = issue_mod.fetch_issues(repo)
    if issues then
      issue = issue_mod.select_issue(issues)
    end
  end

  if err then
    io.stderr:write("error: " .. err .. "\n")
    return 1
  end

  if not issue then
    return 0
  end

  issue_mod.transition_to_doing(issue.url)

  local dir_ok, dir_err = ensure_dir("o/work/plan")
  if not dir_ok then
    io.stderr:write("error: " .. dir_err .. "\n")
    return 1
  end
  util.write_file("o/work/plan/issue.json", json.encode(issue) .. "\n")

  local tpl = prompt.read_prompt("plan.md")
  if not tpl then
    io.stderr:write("error: could not read plan.md prompt\n")
    return 1
  end

  tpl = prompt.interpolate_prompt(tpl, {
    title = issue.title,
    body = issue.body or "",
    issue_number = tostring(issue.number),
    repo_root = unix.getcwd() or ".",
  })

  util.log("plan prompt interpolated (" .. #tpl .. " bytes) for issue #" .. tostring(issue.number))

  local friction = prompt.make_friction_prompt("o/work/plan")
  local ok = sandbox.sandboxed_agent(no_sandbox, tpl, "o/work/plan/session.db", nil, friction, sandbox.plan_limits, model)

  -- Check if plan.md was created, regardless of agent exit status.
  -- The agent may have written plan.md in its final tool call but been
  -- terminated before completing (stop_reason: tool_use instead of end_turn).
  local plan_content = util.read_file("o/work/plan/plan.md")
  if plan_content and #plan_content > 0 then
    -- Plan exists with content - consider successful even if agent didn't exit cleanly
    if not ok then
      util.log("plan agent exited non-zero but plan.md exists, treating as success")
    end
    return 0, issue
  end

  -- No plan.md or empty - this is a failure
  if not ok then
    io.stderr:write("error: plan agent failed\n")
  else
    io.stderr:write("error: plan.md not created\n")
  end
  local diag = prompt.plan_diagnostic("o/work/plan")
  util.log("plan diagnostic: " .. diag)
  return 1
end

local function phase_do(no_sandbox: boolean, title: string, number: string, model: string): integer
  local dir_ok, dir_err = ensure_dir("o/work/do")
  if not dir_ok then
    io.stderr:write("error: " .. dir_err .. "\n")
    return 1
  end

  local plan_contents = util.read_file("o/work/plan/plan.md")
  if not plan_contents then
    io.stderr:write("error: could not read o/work/plan/plan.md\n")
    return 1
  end

  local tpl = prompt.read_prompt("do.md")
  if not tpl then
    io.stderr:write("error: could not read do.md prompt\n")
    return 1
  end

  local branch = util.extract_branch(plan_contents, number)

  tpl = prompt.build_do_prompt(tpl, title, plan_contents, branch, unix.getcwd() or ".")

  local friction = prompt.make_friction_prompt("o/work/do")
  local ok = sandbox.sandboxed_agent(no_sandbox, tpl, "o/work/do/session.db", {"o/work/plan"}, friction, sandbox.do_limits, model)

  -- Always write branch.txt so push phase can find the branch
  util.write_file("o/work/do/branch.txt", branch .. "\n")

  -- Check for partial progress even if agent failed.
  -- With incremental commits, the branch may have useful commits
  -- even when the agent hits a transport error or timeout.
  if not ok then
    local has_commits = util.run({"git", "log", "--oneline", "origin/main..HEAD", "--max-count=1"})
    if has_commits then
      util.log("do agent exited non-zero but branch has commits ahead of main, treating as partial success")
      return 0
    end
    io.stderr:write("error: do agent failed\n")
    return 1
  end

  return 0
end

local function phase_push(work_dir: string): integer
  work_dir = work_dir or "o/work/do"
  local branch_file = work_dir .. "/branch.txt"
  local branch_content = util.read_file(branch_file)
  if not branch_content then
    io.stderr:write("error: could not read " .. branch_file .. "\n")
    return 1
  end

  local branch = branch_content:gsub("%s+$", "")

  local has_parent = util.run({"git", "rev-parse", "--verify", "HEAD~1"})
  if not has_parent then
    return 0
  end

  local same = util.run({"git", "diff", "--quiet", "origin/main...HEAD"})
  if same then
    return 0
  end

  local push_ok = util.run({"git", "push", "-u", "origin", "HEAD:" .. branch})
  if not push_ok then
    io.stderr:write("error: git push failed for branch " .. branch .. "\n")
    return 1
  end

  return 0
end

-- Check if exit code indicates a crash signal (SIGSEGV, SIGBUS, etc.)
-- Exit codes 128+N indicate the process was killed by signal N
local function is_crash_signal(exit_code: integer): boolean
  if exit_code > 128 and exit_code <= 159 then
    local signal = exit_code - 128
    -- SIGSEGV=11, SIGBUS=7, SIGFPE=8, SIGILL=4, SIGABRT=6
    return signal == 11 or signal == 7 or signal == 8 or signal == 4 or signal == 6
  end
  return false
end

local function phase_check(no_sandbox: boolean, model: string, do_dir: string): integer
  do_dir = do_dir or "o/work/do"
  local dir_ok, dir_err = ensure_dir("o/work/check")
  if not dir_ok then
    io.stderr:write("error: " .. dir_err .. "\n")
    return 1
  end

  local plan_contents = util.read_file("o/work/plan/plan.md")
  if not plan_contents then
    io.stderr:write("error: could not read o/work/plan/plan.md\n")
    return 1
  end

  local do_md = do_dir .. "/do.md"
  local do_contents = util.read_file(do_md)
  if not do_contents then
    io.stderr:write("error: could not read " .. do_md .. "\n")
    return 1
  end

  local tpl = prompt.read_prompt("check.md")
  if not tpl then
    io.stderr:write("error: could not read check.md prompt\n")
    return 1
  end

  tpl = prompt.build_check_prompt(tpl, plan_contents, do_contents)

  local protect_dirs: {string} = {"o/work/plan", "o/work/do"}
  if do_dir ~= "o/work/do" then
    table.insert(protect_dirs, do_dir)
  end

  local friction = prompt.make_friction_prompt("o/work/check")

  -- Retry on crash signals (SIGSEGV, SIGBUS, etc.) up to 2 times
  local max_crash_retries = 2
  for attempt = 1, max_crash_retries + 1 do
    local ok, _, exit_code = sandbox.sandboxed_agent(no_sandbox, tpl, "o/work/check/session.db", protect_dirs, friction, sandbox.check_limits, model)

    if ok then
      return 0
    end

    -- Check if it was a crash signal
    if is_crash_signal(exit_code) and attempt <= max_crash_retries then
      io.stderr:write("[work] check agent crashed (signal " .. tostring(exit_code - 128) .. "), retrying (" .. tostring(attempt) .. "/" .. tostring(max_crash_retries) .. ")...\n")
      -- Clear the check directory for retry
      os.execute("rm -rf o/work/check/*")
      ensure_dir("o/work/check")
    else
      io.stderr:write("error: check agent failed (exit code " .. tostring(exit_code) .. ")\n")
      return 1
    end
  end

  return 1
end

local function read_check_verdict(): string
  local content = util.read_file("o/work/check/actions.json")
  if not content then return nil end
  local ok, data = pcall(json.decode, content)
  if not ok or type(data) ~= "table" then return nil end
  return ((data as {string:any}).verdict or "unknown") as string
end

local function phase_fix(no_sandbox: boolean, title: string, number: string, model: string): integer
  local dir_ok, dir_err = ensure_dir("o/work/fix")
  if not dir_ok then
    io.stderr:write("error: " .. dir_err .. "\n")
    return 1
  end

  local plan_contents = util.read_file("o/work/plan/plan.md")
  if not plan_contents then
    io.stderr:write("error: could not read o/work/plan/plan.md\n")
    return 1
  end

  local check_contents = util.read_file("o/work/check/check.md")
  if not check_contents then
    io.stderr:write("error: could not read o/work/check/check.md\n")
    return 1
  end

  local tpl = prompt.read_prompt("fix.md")
  if not tpl then
    io.stderr:write("error: could not read fix.md prompt\n")
    return 1
  end

  local branch = util.extract_branch(plan_contents, number)

  tpl = prompt.build_fix_prompt(tpl, title, plan_contents, check_contents, branch, unix.getcwd() or ".")

  local friction = prompt.make_friction_prompt("o/work/fix")
  local ok = sandbox.sandboxed_agent(no_sandbox, tpl, "o/work/fix/session.db", {"o/work/plan", "o/work/do"}, friction, sandbox.fix_limits, model)

  if not ok then
    io.stderr:write("error: fix agent failed\n")
    return 1
  end

  util.write_file("o/work/fix/branch.txt", branch .. "\n")

  return 0
end

local function phase_act(issue_url: string): integer
  local dir_ok, dir_err = ensure_dir("o/work/act")
  if not dir_ok then
    io.stderr:write("error: " .. dir_err .. "\n")
    return 1
  end

  local act_md = "o/work/act/act.md"
  util.write_file(act_md, "")

  util.tee(act_md, "# Act")

  local actions_content = util.read_file("o/work/check/actions.json")
  if not actions_content then
    util.tee(act_md, "No actions.json found")
    issue_mod.update_labels(issue_url, false)
    return 0
  end

  local ok, actions_data = pcall(json.decode, actions_content)
  if not ok or type(actions_data) ~= "table" then
    util.tee(act_md, "Failed to parse actions.json")
    issue_mod.update_labels(issue_url, false)
    return 1
  end

  local data = actions_data as {string:any}
  local verdict = (data.verdict or "unknown") as string
  util.tee(act_md, "Verdict: " .. verdict)
  util.tee(act_md, "")
  util.tee(act_md, "## Actions")

  local actions = (data.actions or {}) as {{string:any}}
  local all_succeeded = true
  for _, act in ipairs(actions) do
    local log_fn = function(msg: string) util.tee(act_md, msg) end
    local action_ok = action.execute_action(issue_url, act, log_fn)
    if not action_ok then all_succeeded = false end
  end

  local success = verdict == "pass" and all_succeeded
  util.write_file("o/work/act/results.json", json.encode({
    verdict = verdict,
    success = success
  }) .. "\n")

  issue_mod.update_labels(issue_url, success)

  return 0
end

-- Friction analysis phase: sandboxed agent analyzes all outputs

local function phase_analyze(no_sandbox: boolean, repo: string, model: string): integer
  local dir_ok, dir_err = ensure_dir("o/work/analyze")
  if not dir_ok then
    io.stderr:write("error: " .. dir_err .. "\n")
    return 1
  end

  local tpl = prompt.read_prompt("analyze.md")
  if not tpl then
    io.stderr:write("error: could not read analyze.md prompt\n")
    return 1
  end

  tpl = prompt.interpolate_prompt(tpl, {
    repo = repo,
  })

  -- Protect all existing phase output directories (read-only)
  local protect_dirs: {string} = {"o/work/plan", "o/work/do", "o/work/check", "o/work/fix", "o/work/act"}

  local ok = sandbox.sandboxed_agent(no_sandbox, tpl, "o/work/analyze/session.db", protect_dirs, nil, analyze_limits, model)

  if not ok then
    io.stderr:write("error: analyze agent failed\n")
    return 1
  end

  return 0
end

-- File friction issues deterministically from analyze output

local function file_friction_issues(repo: string): integer
  local content = util.read_file("o/work/analyze/issues.json")
  if not content then
    util.log("no issues.json found in analyze output")
    return 0
  end

  local parsed, err = parse_friction_issues(content)
  if not parsed then
    util.log("failed to parse issues.json: " .. (err or "unknown"))
    return 1
  end

  if #parsed.issues == 0 then
    util.log("no friction issues to file")
    return 0
  end

  local max_issues = 3
  local filed = 0
  for i, issue in ipairs(parsed.issues) do
    if i > max_issues then break end

    local valid, verr = validate_friction_issue(issue)
    if not valid then
      util.log("skipping invalid friction issue: " .. (verr or "unknown"))
    else
      local cmd: {string} = {"gh", "issue", "create", "--repo", repo, "--title", issue.title, "--body", issue.body}
      for _, label in ipairs(issue.labels) do
        table.insert(cmd, "--label")
        table.insert(cmd, label)
      end

      local ok = util.run(cmd)
      if ok then
        filed = filed + 1
        util.log("filed friction issue: " .. issue.title)
      else
        util.log("failed to file friction issue: " .. issue.title)
      end
    end
  end

  util.log("filed " .. tostring(filed) .. " friction issues")
  return 0
end

-- CLI

local function usage()
  io.stderr:write([[usage: ah work [command] [options]

commands:
  (default)  run all phases: plan, do, push, check, act, analyze
  plan       select issue and create plan
  do         execute plan
  check      verify execution
  act        execute actions
  push       push work branch
  analyze    analyze friction and file issues

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

local function cmd_analyze(no_sandbox: boolean, args: {string}, model: string): integer
  local repo: string

  local longopts = {
    {name = "help", has_arg = "none", short = "h"},
    {name = "repo", has_arg = "required", short = "r"},
  }

  local parser = getopt.new(args, "hr:", longopts)

  while true do
    local opt, optarg = parser:next()
    if not opt then break end
    if opt == "h" or opt == "help" then
      io.stderr:write("usage: ah work analyze --repo <owner/repo>\n")
      return 0
    elseif opt == "r" or opt == "repo" then
      repo = optarg
    elseif opt == "?" then
      io.stderr:write("usage: ah work analyze --repo <owner/repo>\n")
      return 1
    end
  end

  if not repo then
    io.stderr:write("usage: ah work analyze --repo <owner/repo>\n")
    return 1
  end

  local rc = phase_analyze(no_sandbox, repo, model)
  if rc == 0 then
    file_friction_issues(repo)
  end
  return rc
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
    return cmd_plan(no_sandbox, util.slice(filtered_args, 2), model)
  elseif subcmd == "do" then
    return cmd_do(no_sandbox, util.slice(filtered_args, 2), model)
  elseif subcmd == "check" then
    return phase_check(no_sandbox, model, "o/work/do")
  elseif subcmd == "act" then
    return cmd_act(util.slice(filtered_args, 2))
  elseif subcmd == "push" then
    return phase_push("o/work/do")
  elseif subcmd == "analyze" then
    return cmd_analyze(no_sandbox, util.slice(filtered_args, 2), model)
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
  issue_mod.ensure_labels(repo)

  -- Create issue from prompt template if specified
  if prompt_name then
    if issue_number then
      io.stderr:write("error: --prompt and --issue are mutually exclusive\n")
      return 1
    end
    local num, err = issue_mod.create_issue_from_prompt(repo, prompt_name, prompt.read_prompt_template)
    if not num then
      io.stderr:write("error: " .. (err or "unknown") .. "\n")
      return 1
    end
    issue_number = tostring(num)
    io.stderr:write("created issue #" .. issue_number .. " from prompt: " .. prompt_name .. "\n")
  end

  local start_time = util.now_sec()
  local deadline = start_time + sandbox.overall_timeout_sec

  local function check_deadline(phase: string): boolean
    if util.now_sec() > deadline then
      io.stderr:write("error: overall timeout exceeded before " .. phase .. " phase\n")
      return false
    end
    return true
  end

  -- Always create work directory for artifacts
  local work_dir_ok, work_dir_err = ensure_dir("o/work")
  if not work_dir_ok then
    io.stderr:write("error: " .. work_dir_err .. "\n")
    return 1
  end

  -- Helper to write run summary
  local function write_summary(status: string, issue_num: integer, phases_completed: {string})
    local summary = {
      status = status,
      issue = issue_num,
      phases = phases_completed,
      started_at = start_time,
      ended_at = util.now_sec(),
      repo = repo,
    }
    util.write_file("o/work/summary.json", json.encode(summary) .. "\n")
  end

  -- PDCA workflow (may fail at any phase)
  local pdca_rc = 0
  local phases_completed: {string} = {}

  -- Phase 1: Plan (agent — sandboxed)
  io.stderr:write("==> plan\n")
  local issue_num: integer = nil
  if issue_number then
    issue_num = tonumber(issue_number) as integer
  end
  local rc: integer
  local issue: Issue
  rc, issue = phase_plan(no_sandbox, repo, issue_num, model)

  if rc ~= 0 then
    pdca_rc = rc
    write_summary("plan_failed", issue_num, phases_completed)
  elseif not issue then
    io.stderr:write("no issues to work on\n")
    write_summary("no_issues", nil, phases_completed)
    return 0
  end
  table.insert(phases_completed, "plan")

  if pdca_rc == 0 then
    local max_fix_retries = 2
    local issue_number_str = tostring(issue.number)

    -- Phase 2: Do (agent — sandboxed)
    if not check_deadline("do") then
      pdca_rc = 1
    else
      io.stderr:write("==> do\n")
      rc = phase_do(no_sandbox, issue.title, issue_number_str, model)
      if rc ~= 0 then pdca_rc = rc else table.insert(phases_completed, "do") end
    end

    -- Phase 3: Push (deterministic — unsandboxed)
    if pdca_rc == 0 then
      if not check_deadline("push") then
        pdca_rc = 1
      else
        io.stderr:write("==> push\n")
        rc = phase_push("o/work/do")
        if rc ~= 0 then pdca_rc = rc else table.insert(phases_completed, "push") end
      end
    end

    -- Phase 4: Check (agent — sandboxed)
    if pdca_rc == 0 then
      if not check_deadline("check") then
        pdca_rc = 1
      else
        io.stderr:write("==> check\n")
        rc = phase_check(no_sandbox, model, "o/work/do")
        if rc ~= 0 then pdca_rc = rc else table.insert(phases_completed, "check") end
      end
    end

    -- Retry loop: if check returns needs-fixes, run fix/push/check
    if pdca_rc == 0 then
      for attempt = 1, max_fix_retries do
        local verdict = read_check_verdict()
        if verdict ~= "needs-fixes" then break end
        if not check_deadline("fix") then break end

        io.stderr:write("==> fix (attempt " .. tostring(attempt) .. "/" .. tostring(max_fix_retries) .. ")\n")
        rc = phase_fix(no_sandbox, issue.title, issue_number_str, model)
        if rc ~= 0 then break end
        table.insert(phases_completed, "fix")

        if not check_deadline("push") then break end
        io.stderr:write("==> push\n")
        rc = phase_push("o/work/fix")
        if rc ~= 0 then break end

        if not check_deadline("check") then break end
        io.stderr:write("==> check\n")
        rc = phase_check(no_sandbox, model, "o/work/fix")
        if rc ~= 0 then break end
      end
    end

    -- Phase 5: Act (deterministic — unsandboxed)
    io.stderr:write("==> act\n")
    rc = phase_act(issue.url)
    if rc ~= 0 and pdca_rc == 0 then pdca_rc = rc else table.insert(phases_completed, "act") end
  end

  -- Phase 6: Analyze friction (always runs when work was attempted)
  if util.read_file("o/work/plan/issue.json") then
    io.stderr:write("==> analyze\n")
    local analyze_rc = phase_analyze(no_sandbox, repo, model)
    if analyze_rc == 0 then
      file_friction_issues(repo)
      table.insert(phases_completed, "analyze")
    end
  end

  -- Write final summary
  local final_status = pdca_rc == 0 and "success" or "failed"
  write_summary(final_status, issue and issue.number or nil, phases_completed)

  return pdca_rc
end

return {
  main = main,
  -- internal functions exported for testing
  is_crash_signal = is_crash_signal,
  -- re-exported from submodules for backward compatibility
  get_priority = issue_mod.get_priority,
  sort_issues = issue_mod.sort_issues,
  select_issue = issue_mod.select_issue,
  extract_branch = util.extract_branch,
  parse_actions = action.parse_actions,
  validate_branch = action.validate_branch,
  execute_action = action.execute_action,
  slice = util.slice,
  required_labels = issue_mod.required_labels,
  ensure_labels = issue_mod.ensure_labels,
  interpolate_prompt = prompt.interpolate_prompt,
  plan_diagnostic = prompt.plan_diagnostic,
  build_do_prompt = prompt.build_do_prompt,
  build_check_prompt = prompt.build_check_prompt,
  issue_number_from_url = action.issue_number_from_url,
  build_pr_body = action.build_pr_body,
  format_run_error = util.format_run_error,
  format_protect_dirs = util.format_protect_dirs,
  build_fix_prompt = prompt.build_fix_prompt,
  build_friction_prompt = prompt.build_friction_prompt,
  build_agent_args = sandbox.build_agent_args,
  setup_git_env = util.setup_git_env,
  parse_friction_issues = parse_friction_issues,
  validate_friction_issue = validate_friction_issue,
}
