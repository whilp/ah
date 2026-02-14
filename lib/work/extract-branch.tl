-- lib/work/extract-branch.tl: extract branch name from plan.md
-- outputs just the branch name to stdout
local json = require("cosmic.json")

local function read_file(path: string): string
   local f = io.open(path, "r")
   if not f then return nil end
   local content = f:read("*a")
   f:close()
   return content
end

local plan_file = arg[1]
local issue_file = arg[2]

if not plan_file then
   io.stderr:write("usage: extract-branch.tl <plan.md> [issue.json]\n")
   os.exit(1)
end

local plan = read_file(plan_file)
if not plan then
   io.stderr:write("could not read " .. plan_file .. "\n")
   os.exit(1)
end

local branch = plan:match("Branch: ([^\n]+)")
if not branch then
   -- fallback: use issue number
   local default_number = "0"
   if issue_file then
      local issue_raw = read_file(issue_file)
      if issue_raw then
         local issue = json.decode(issue_raw) as {string:any}
         if issue and issue.number then
            default_number = tostring(issue.number)
         end
      end
   end
   branch = "work/" .. default_number
end

io.write(branch)
