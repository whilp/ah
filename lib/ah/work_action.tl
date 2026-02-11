-- ah/work_action.tl: action parsing, validation, and execution
local json = require("cosmic.json")
local util = require("ah.work_util")

local record ParsedActions
  verdict: string
  actions: {{string:any}}
  success: boolean
end

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

local function issue_number_from_url(url: string): string
  if not url then return nil end
  return url:match("/issues/(%d+)")
end

local function build_pr_body(body: string, issue_url: string): string
  body = body or ""
  local num = issue_number_from_url(issue_url)
  if num then
    local ref = "Closes #" .. num
    if not body:find(ref, 1, true) then
      body = body .. "\n\n" .. ref
    end
  end
  return body
end

local function execute_comment_issue(issue_url: string, body: string): boolean, string
  if not body then return false, "missing body" end
  local ok, stdout, _, stderr = util.run({"gh", "issue", "comment", issue_url, "--body", body})
  if not ok then return false, util.format_run_error("gh issue comment failed", stdout, stderr) end
  return true
end

local function execute_create_pr(branch: string, title: string, body: string): boolean, string
  local valid, verr = validate_branch(branch)
  if not valid then return false, verr end
  if not title then return false, "missing title" end
  if not body then return false, "missing body" end
  local ok, stdout, _, stderr = util.run({"gh", "pr", "create", "--head", branch, "--title", title, "--body", body})
  if not ok then return false, util.format_run_error("gh pr create failed", stdout, stderr) end
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
    local body = build_pr_body(action.body as string, issue_url)
    local ok, err = execute_create_pr(action.branch as string, action.title as string, body)
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

return {
  parse_actions = parse_actions,
  validate_branch = validate_branch,
  issue_number_from_url = issue_number_from_url,
  build_pr_body = build_pr_body,
  execute_action = execute_action,
}
