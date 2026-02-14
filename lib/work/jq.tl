-- lib/work/jq.tl: extract a field from a json file
-- usage: jq.tl --file <path> --field <name>
local json = require("cosmic.json")
local getopt = require("cosmic.getopt")

local function read_file(path: string): string
   local f = io.open(path, "r")
   if not f then return nil end
   local content = f:read("*a")
   f:close()
   return content
end

local file: string
local field: string

local longopts = {
   {name = "file", has_arg = "required", short = "f"},
   {name = "field", has_arg = "required", short = "k"},
}
local parser = getopt.new(arg, "f:k:", longopts)

while true do
   local opt, optarg = parser:next()
   if not opt then break end
   if opt == "f" or opt == "file" then
      file = optarg
   elseif opt == "k" or opt == "field" then
      field = optarg
   elseif opt == "?" then
      io.stderr:write("usage: jq.tl --file <path> --field <name>\n")
      os.exit(1)
   end
end

if not file or not field then
   io.stderr:write("usage: jq.tl --file <path> --field <name>\n")
   os.exit(1)
end

local raw = read_file(file)
if not raw then
   io.stderr:write("could not read " .. file .. "\n")
   os.exit(1)
end

local data = json.decode(raw) as {string:any}
if not data then
   io.stderr:write("could not parse " .. file .. "\n")
   os.exit(1)
end

local val = data[field]
if val == nil then
   os.exit(1)
end

io.write(tostring(val))
