-- lib/work/pr-limit.tl: exit 1 if too many open PRs
-- reads: WORK_REPO, WORK_MAX_PRS
local json = require("cosmic.json")

local repo = os.getenv("WORK_REPO")
if not repo or repo == "" then
   io.stderr:write("error: WORK_REPO not set\n")
   os.exit(1)
end

local max_prs = tonumber(os.getenv("WORK_MAX_PRS")) or 4

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
