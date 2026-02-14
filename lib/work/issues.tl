-- lib/work/issues.tl: fetch open todo issues as json
local json = require("cosmic.json")
local getopt = require("cosmic.getopt")

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

local repo: string

local longopts = {
   {name = "repo", has_arg = "required", short = "r"},
}
local parser = getopt.new(arg, "r:", longopts)

while true do
   local opt, optarg = parser:next()
   if not opt then break end
   if opt == "r" or opt == "repo" then
      repo = optarg
   elseif opt == "?" then
      io.stderr:write("usage: issues.tl --repo <owner/repo>\n")
      os.exit(1)
   end
end

if not repo then
   io.stderr:write("usage: issues.tl --repo <owner/repo>\n")
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

io.write(json.encode(issues))
