-- lib/work/push.tl: push work branch to origin
-- reads: WORK_ISSUE (path to issue.json with branch field)
local json = require("cosmic.json")

local function read_file(path: string): string
   local f = io.open(path, "r")
   if not f then return nil end
   local content = f:read("*a")
   f:close()
   return content
end

local function run(cmd: string): boolean
   local rc = os.execute(cmd)
   return rc as boolean
end

local issue_file = os.getenv("WORK_ISSUE")
if not issue_file or issue_file == "" then
   io.stderr:write("error: WORK_ISSUE not set\n")
   os.exit(1)
end

local issue_raw = read_file(issue_file)
if not issue_raw then
   io.stderr:write("could not read " .. issue_file .. "\n")
   os.exit(1)
end

local issue = json.decode(issue_raw) as {string:any}
local branch = (issue.branch or "") as string
if branch == "" then
   io.stderr:write("no branch in issue.json\n")
   os.exit(1)
end

-- check if there are commits ahead of main
if not run("git rev-parse --verify HEAD~1 >/dev/null 2>&1") then
   os.exit(0)
end

-- check if there are actual changes
if run("git diff --quiet origin/main...HEAD") then
   os.exit(0)
end

-- push
if not run("git push -u origin HEAD:" .. branch) then
   io.stderr:write("git push failed for branch " .. branch .. "\n")
   os.exit(1)
end
