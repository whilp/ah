-- lib/work/check-pr-limit.tl: exit 1 if too many open PRs
local json = require("cosmic.json")
local getopt = require("cosmic.getopt")

local repo: string
local max_prs = 4

local longopts = {
   {name = "repo", has_arg = "required", short = "r"},
   {name = "max", has_arg = "required", short = "n"},
}
local parser = getopt.new(arg, "r:n:", longopts)

while true do
   local opt, optarg = parser:next()
   if not opt then break end
   if opt == "r" or opt == "repo" then
      repo = optarg
   elseif opt == "n" or opt == "max" then
      max_prs = tonumber(optarg) or 4
   elseif opt == "?" then
      io.stderr:write("usage: check-pr-limit.tl --repo <owner/repo> [--max <n>]\n")
      os.exit(1)
   end
end

if not repo then
   io.stderr:write("usage: check-pr-limit.tl --repo <owner/repo> [--max <n>]\n")
   os.exit(1)
end

local p = io.popen("gh pr list --repo " .. repo .. " --state open --json number 2>&1")
if not p then
   io.stderr:write("failed to run gh pr list\n")
   os.exit(1)
end

local out = p:read("*a")
p:close()

local prs = json.decode(out) as {any}
if not prs then
   io.stderr:write("warning: could not parse PR list\n")
   os.exit(0)
end

if #prs > max_prs then
   io.stderr:write("pr limit reached: " .. tostring(#prs) .. " open PRs (max " .. tostring(max_prs) .. ")\n")
   os.exit(1)
end
