-- lib/work/issues.tl: fetch open todo issues as json
-- reads: WORK_REPO
-- writes: json to stdout
local json = require("cosmic.json")

local function run(cmd: {string}): string
   local p = io.popen(table.concat(cmd, " "))
   if not p then
      io.stderr:write("failed to run: " .. table.concat(cmd, " ") .. "\n")
      os.exit(1)
   end
   local out = p:read("*a")
   p:close()
   return out
end

local repo = os.getenv("WORK_REPO")
if not repo or repo == "" then
   io.stderr:write("error: WORK_REPO not set\n")
   os.exit(1)
end

local raw = run({
   "gh", "issue", "list",
   "--repo", repo,
   "--label", "todo",
   "--state", "open",
   "--json", "number,title,body,url,labels,createdAt",
   "--limit", "100",
})

local issues = json.decode(raw)
if not issues then
   io.stderr:write("failed to parse issues json\n")
   os.exit(1)
end

io.write((json.encode(issues)))
