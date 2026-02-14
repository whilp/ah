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
  count_open_prs: function(string): integer, string
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

local record PromptMod
  read_prompt: function(string): string
  read_prompt_template: function(string): string
  interpolate_prompt: function(string, {string:string}): string
  plan_diagnostic: function(string): string
  build_do_prompt: function(string, string, string, string, string): string
  build_check_prompt: function(string, string, string): string
  build_fix_prompt: function(string, string, string, string, string, string): string
  build_plan_prompt: function(string, string, string, string): string
end

local record PhaseOpts
  sandbox: boolean
  timeout: integer
  unveil_dirs: {string}
  db: string
  prompt: string
  max_tokens: integer
  model: string
end

local record SandboxMod
  overall_timeout_sec: number
  plan_limits: AgentLimits
  do_limits: AgentLimits
  check_limits: AgentLimits
  fix_limits: AgentLimits
  run_phase: function(PhaseOpts): boolean, string, integer
  build_phase_args: function(string, PhaseOpts): {string}
end

local util = require("ah.work.util") as Util
local issue_mod = require("ah.work.issue") as IssueMod
local action = require("ah.work.action") as ActionMod
local prompt = require("ah.work.prompt") as PromptMod
local sandbox = require("ah.work.sandbox") as SandboxMod

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

  local ok = sandbox.run_phase({
    sandbox = not no_sandbox,
    timeout = sandbox.plan_limits.timeout_sec,
    db = "o/work/plan/session.db",
    prompt = tpl,
    max_tokens = sandbox.plan_limits.max_tokens,
    model = model,
  })

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

  local ok = sandbox.run_phase({
    sandbox = not no_sandbox,
    timeout = sandbox.do_limits.timeout_sec,
    unveil_dirs = {"o/work/plan"},
    db = "o/work/do/session.db",
    prompt = tpl,
    max_tokens = sandbox.do_limits.max_tokens,
    model = model,
  })

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

  -- Retry on crash signals (SIGSEGV, SIGBUS, etc.) up to 2 times
  local max_crash_retries = 2
  for attempt = 1, max_crash_retries + 1 do
    local ok, _, exit_code = sandbox.run_phase({
      sandbox = not no_sandbox,
      timeout = sandbox.check_limits.timeout_sec,
      unveil_dirs = protect_dirs,
      db = "o/work/check/session.db",
      prompt = tpl,
      max_tokens = sandbox.check_limits.max_tokens,
      model = model,
    })

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

-- Truncate a string to max_len, appending "..." if truncated
local function truncate(s: string, max_len: integer): string
  if not s or #s <= max_len then return s end
  return s:sub(1, max_len) .. "\n..."
end

-- Extract a section from a markdown document by heading
local function extract_section(content: string, heading: string, max_len: integer): string
  if not content then return nil end
  local pattern = "## " .. heading .. "\n"
  local start = content:find(pattern, 1, true)
  if not start then
    pattern = "# " .. heading .. "\n"
    start = content:find(pattern, 1, true)
  end
  if not start then return nil end
  local section_start = content:find("\n", start, true)
  if not section_start then return nil end
  section_start = section_start + 1
  -- find next heading
  local section_end = content:find("\n#", section_start)
  local section: string
  if section_end then
    section = content:sub(section_start, section_end - 1)
  else
    section = content:sub(section_start)
  end
  return truncate(section:gsub("^%s+", ""):gsub("%s+$", ""), max_len)
end

-- Build a markdown summary comment from available phase artifacts
local function build_summary_comment(status: string, phases_completed: {string}): string
  local lines: {string} = {}
  local function add(s: string)
    table.insert(lines, s)
  end

  -- status emoji
  local emoji = "❌"
  if status == "success" then emoji = "✅"
  elseif status == "no_issues" then emoji = "⚪"
  end

  add("## 🤖 Work Summary")
  add("")
  add("**Status**: " .. emoji .. " `" .. status .. "`")

  -- branch
  local branch_content = util.read_file("o/work/do/branch.txt")
  if branch_content then
    local branch = branch_content:gsub("%s+$", "")
    if branch ~= "" then
      add("**Branch**: `" .. branch .. "`")
    end
  end

  -- workflow run link
  local server = os.getenv("GITHUB_SERVER_URL")
  local repository = os.getenv("GITHUB_REPOSITORY")
  local run_id = os.getenv("GITHUB_RUN_ID")
  if server and repository and run_id then
    add("**Run**: [workflow run](" .. server .. "/" .. repository .. "/actions/runs/" .. run_id .. ")")
  end

  add("**Phases**: " .. (phases_completed and #phases_completed > 0 and table.concat(phases_completed, " → ") or "none"))
  add("")

  -- On success, keep it short — the act phase's comment_issue has details
  if status == "success" then
    local check_md = util.read_file("o/work/check/check.md")
    local verdict_text = extract_section(check_md, "Verdict", 200)
    if verdict_text then
      add("### Verdict")
      add(verdict_text)
      add("")
    end
    return truncate(table.concat(lines, "\n"), 4000)
  end

  -- On failure, include details from available artifacts
  local plan_md = util.read_file("o/work/plan/plan.md")
  if plan_md then
    local goal = extract_section(plan_md, "Goal", 500)
    if goal then
      add("### Goal")
      add(goal)
      add("")
    end
  else
    add("### Plan")
    add("Plan phase did not complete.")
    add("")
  end

  local do_md = util.read_file("o/work/do/do.md")
  if do_md then
    local changes = extract_section(do_md, "Changes", 500)
    if changes then
      add("### Changes")
      add(changes)
      add("")
    end
    local do_status = extract_section(do_md, "Status", 200)
    if do_status then
      add("### Implementation Status")
      add(do_status)
      add("")
    end
  elseif plan_md then
    add("### Changes")
    add("Implementation phase did not complete.")
    add("")
  end

  local check_md = util.read_file("o/work/check/check.md")
  if check_md then
    local verdict_text = extract_section(check_md, "Verdict", 500)
    if verdict_text then
      add("### Verdict")
      add(verdict_text)
      add("")
    end
  end

  return truncate(table.concat(lines, "\n"), 4000)
end

-- Post a summary comment on the originating issue (best-effort)
local function post_summary_comment(issue_url: string, status: string, phases_completed: {string})
  local body = build_summary_comment(status, phases_completed)
  if not body or body == "" then
    util.log("post_summary_comment: empty body, skipping")
    return
  end
  local ok, _, _, stderr = util.run({"gh", "issue", "comment", issue_url, "--body", body})
  if not ok then
    util.log("post_summary_comment: failed to post comment: " .. (stderr or "unknown error"))
  else
    util.log("post_summary_comment: comment posted on " .. issue_url)
  end
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

  local ok = sandbox.run_phase({
    sandbox = not no_sandbox,
    timeout = sandbox.fix_limits.timeout_sec,
    unveil_dirs = {"o/work/plan", "o/work/do"},
    db = "o/work/fix/session.db",
    prompt = tpl,
    max_tokens = sandbox.fix_limits.max_tokens,
    model = model,
  })

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
    return cmd_plan(no_sandbox, util.slice(filtered_args, 2), model)
  elseif subcmd == "do" then
    return cmd_do(no_sandbox, util.slice(filtered_args, 2), model)
  elseif subcmd == "check" then
    return phase_check(no_sandbox, model, "o/work/do")
  elseif subcmd == "act" then
    return cmd_act(util.slice(filtered_args, 2))
  elseif subcmd == "push" then
    return phase_push("o/work/do")
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

  -- Bail if too many open PRs
  local pr_count, pr_err = issue_mod.count_open_prs(repo)
  if pr_count and pr_count > 4 then
    util.log("pr limit reached: " .. tostring(pr_count) .. " open PRs (max 4), bailing")
    local work_dir_ok2, work_dir_err2 = ensure_dir("o/work")
    if work_dir_ok2 then
      local summary = {
        status = "pr_limit",
        pr_count = pr_count,
        repo = repo,
      }
      util.write_file("o/work/summary.json", json.encode(summary) .. "\n")
    else
      io.stderr:write("error: " .. work_dir_err2 .. "\n")
    end
    return 0
  elseif pr_err then
    util.log("warning: could not count open PRs: " .. pr_err)
  end

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

  -- Write final summary
  local final_status = pdca_rc == 0 and "success" or "failed"
  write_summary(final_status, issue and issue.number or nil, phases_completed)

  -- Post summary comment on the originating issue (best-effort)
  local comment_url: string = issue and issue.url or nil
  if not comment_url then
    -- Try reading from issue.json written during plan phase
    local issue_json = util.read_file("o/work/plan/issue.json")
    if issue_json then
      local decode_ok, issue_data = pcall(json.decode, issue_json)
      if decode_ok and type(issue_data) == "table" then
        comment_url = ((issue_data as {string:any}).url) as string
      end
    end
  end
  if comment_url then
    post_summary_comment(comment_url, final_status, phases_completed)
  end

  return pdca_rc
end

return {
  main = main,
  -- internal functions exported for testing
  is_crash_signal = is_crash_signal,
  build_summary_comment = build_summary_comment,
  -- re-exported from submodules for backward compatibility
  count_open_prs = issue_mod.count_open_prs,
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
  build_phase_args = sandbox.build_phase_args,
  setup_git_env = util.setup_git_env,
}
