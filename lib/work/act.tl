-- lib/work/act.tl: execute actions from check phase
-- args: issue.json actions.json branch.txt
local json = require("cosmic.json")

local function read_file(path: string): string
   local f = io.open(path, "r")
   if not f then return nil end
   local content = f:read("*a")
   f:close()
   return content
end

local function run(cmd: string): boolean, string
   local p = io.popen(cmd .. " 2>&1")
   if not p then return false, "popen failed" end
   local out = p:read("*a")
   local ok = p:close()
   return ok == true or ok == 0, out
end

local function issue_number_from_url(url: string): string
   if not url then return nil end
   return url:match("/issues/(%d+)")
end

local issue_file = arg[1]
local actions_file = arg[2]
local branch_file = arg[3]

if not issue_file or not actions_file then
   io.stderr:write("usage: act.tl <issue.json> <actions.json> [branch.txt]\n")
   os.exit(1)
end

local issue_raw = read_file(issue_file)
if not issue_raw then
   io.stderr:write("could not read " .. issue_file .. "\n")
   os.exit(1)
end
local issue = json.decode(issue_raw) as {string:any}
local issue_url = (issue.url or "") as string

local actions_raw = read_file(actions_file)
if not actions_raw then
   io.stderr:write("no actions.json found, updating labels as failed\n")
   run("gh issue edit '" .. issue_url .. "' --remove-label doing --add-label failed")
   os.exit(0)
end

local data = json.decode(actions_raw) as {string:any}
if not data then
   io.stderr:write("could not parse " .. actions_file .. "\n")
   run("gh issue edit '" .. issue_url .. "' --remove-label doing --add-label failed")
   os.exit(1)
end

local verdict = (data.verdict or "unknown") as string
local actions = (data.actions or {}) as {{string:any}}

io.stderr:write("verdict: " .. verdict .. "\n")

local all_ok = true
for _, act in ipairs(actions) do
   local action_type = (act.action or "unknown") as string
   io.stderr:write("executing: " .. action_type .. "\n")

   if action_type == "comment_issue" then
      local body = (act.body or "") as string
      local ok, out = run("gh issue comment '" .. issue_url .. "' --body '" .. body:gsub("'", "'\\''") .. "'")
      if not ok then
         io.stderr:write("  failed: " .. (out or "") .. "\n")
         all_ok = false
      end

   elseif action_type == "create_pr" then
      local branch = (act.branch or "") as string
      local title = (act.title or "") as string
      local body = (act.body or "") as string

      -- append closes reference
      local num = issue_number_from_url(issue_url)
      if num then
         local ref = "Closes #" .. num
         if not body:find(ref, 1, true) then
            body = body .. "\n\n" .. ref
         end
      end

      local ok, out = run("gh pr create --head '" .. branch .. "' --title '" .. title:gsub("'", "'\\''") .. "' --body '" .. body:gsub("'", "'\\''") .. "'")
      if not ok then
         io.stderr:write("  failed: " .. (out or "") .. "\n")
         all_ok = false
      end
   else
      io.stderr:write("  skipped unknown action: " .. action_type .. "\n")
   end
end

-- update labels
local success = verdict == "pass" and all_ok
run("gh issue edit '" .. issue_url .. "' --remove-label doing")
if success then
   run("gh issue edit '" .. issue_url .. "' --add-label done")
else
   run("gh issue edit '" .. issue_url .. "' --add-label failed")
end

-- write results
local results = json.encode({verdict = verdict, success = success})
local f = io.open("o/work/act/results.json", "w")
if f then
   f:write(results .. "\n")
   f:close()
end
