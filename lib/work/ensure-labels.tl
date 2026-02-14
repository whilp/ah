-- lib/work/ensure-labels.tl: ensure required labels exist in the repo
local getopt = require("cosmic.getopt")

local labels = {"todo", "doing", "done", "failed", "friction"}

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
      io.stderr:write("usage: ensure-labels.tl --repo <owner/repo>\n")
      os.exit(1)
   end
end

if not repo then
   io.stderr:write("usage: ensure-labels.tl --repo <owner/repo>\n")
   os.exit(1)
end

for _, label in ipairs(labels) do
   os.execute("gh label create " .. label .. " --repo " .. repo .. " --force 2>/dev/null")
end
