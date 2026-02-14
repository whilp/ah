-- lib/work/transition.tl: transition issue label from todo to doing
local json = require("cosmic.json")
local getopt = require("cosmic.getopt")

local function read_file(path: string): string
   local f = io.open(path, "r")
   if not f then return nil end
   local content = f:read("*a")
   f:close()
   return content
end

local issue_file: string

local longopts = {
   {name = "issue", has_arg = "required", short = "i"},
}
local parser = getopt.new(arg, "i:", longopts)

while true do
   local opt, optarg = parser:next()
   if not opt then break end
   if opt == "i" or opt == "issue" then
      issue_file = optarg
   elseif opt == "?" then
      io.stderr:write("usage: transition.tl --issue <issue.json>\n")
      os.exit(1)
   end
end

if not issue_file then
   io.stderr:write("usage: transition.tl --issue <issue.json>\n")
   os.exit(1)
end

local issue_raw = read_file(issue_file)
if not issue_raw then
   io.stderr:write("could not read " .. issue_file .. "\n")
   os.exit(1)
end

local issue = json.decode(issue_raw) as {string:any}
local url = (issue.url or "") as string

if url == "" then
   io.stderr:write("no url in issue.json\n")
   os.exit(1)
end

io.stderr:write("transitioning issue to doing: " .. url .. "\n")
os.execute("gh issue edit '" .. url .. "' --remove-label todo --add-label doing")
