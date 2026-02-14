-- lib/work/check-verdict.tl: read verdict from actions.json
-- exits 0 and prints verdict, or exits 1 if no verdict found
local json = require("cosmic.json")
local getopt = require("cosmic.getopt")

local function read_file(path: string): string
   local f = io.open(path, "r")
   if not f then return nil end
   local content = f:read("*a")
   f:close()
   return content
end

local actions_file: string

local longopts = {
   {name = "actions", has_arg = "required", short = "a"},
}
local parser = getopt.new(arg, "a:", longopts)

while true do
   local opt, optarg = parser:next()
   if not opt then break end
   if opt == "a" or opt == "actions" then
      actions_file = optarg
   elseif opt == "?" then
      io.stderr:write("usage: check-verdict.tl --actions <actions.json>\n")
      os.exit(1)
   end
end

if not actions_file then
   io.stderr:write("usage: check-verdict.tl --actions <actions.json>\n")
   os.exit(1)
end

local raw = read_file(actions_file)
if not raw then
   io.stderr:write("could not read " .. actions_file .. "\n")
   os.exit(1)
end

local data = json.decode(raw) as {string:any}
if not data then
   io.stderr:write("could not parse " .. actions_file .. "\n")
   os.exit(1)
end

io.write((data.verdict or "unknown") as string)
