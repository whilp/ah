-- ah/work/issue.tl: issue types, selection, labels, and GitHub operations
local json = require("cosmic.json")
local util = require("ah.work.util")

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

-- Labels used throughout the PDCA workflow
local required_labels: {string} = {"todo", "doing", "done", "failed", "friction"}

local function ensure_labels(repo: string): boolean, string
  for _, label in ipairs(required_labels) do
    util.run({"gh", "label", "create", label, "--repo", repo, "--force"})
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
  local ok, stdout = util.run({
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
  local ok, stdout = util.run({
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

local function create_issue_from_prompt(repo: string, prompt_name: string, read_prompt_template: function(string): string): integer, string
  local body = read_prompt_template(prompt_name)
  if not body then
    return nil, "unknown prompt: " .. prompt_name
  end
  util.log("creating issue from prompt: " .. prompt_name .. " (body length: " .. #body .. ")")
  local ok, stdout = util.run({
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
  util.log("transitioning issue to doing: " .. issue_url)
  util.run({"gh", "issue", "edit", issue_url, "--remove-label", "todo", "--add-label", "doing"})
end

local function update_labels(issue_url: string, success: boolean)
  util.log("updating labels for: " .. issue_url .. " (success: " .. tostring(success) .. ")")
  util.run({"gh", "issue", "edit", issue_url, "--remove-label", "doing"})
  if success then
    util.run({"gh", "issue", "edit", issue_url, "--add-label", "done"})
  else
    util.run({"gh", "issue", "edit", issue_url, "--add-label", "failed"})
  end
end

return {
  get_priority = get_priority,
  sort_issues = sort_issues,
  fetch_issues = fetch_issues,
  select_issue = select_issue,
  fetch_issue = fetch_issue,
  create_issue_from_prompt = create_issue_from_prompt,
  transition_to_doing = transition_to_doing,
  update_labels = update_labels,
  required_labels = required_labels,
  ensure_labels = ensure_labels,
}
