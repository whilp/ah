-- lib/work/check-pr-limit.tl: exit 1 if too many open PRs
local json = require("cosmic.json")

local repo = arg[1]
local max_prs = tonumber(arg[2]) or 4

if not repo then
   io.stderr:write("usage: check-pr-limit.tl <owner/repo> [max_prs]\n")
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
