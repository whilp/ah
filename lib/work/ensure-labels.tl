-- lib/work/ensure-labels.tl: ensure required labels exist in the repo
local labels = {"todo", "doing", "done", "failed", "friction"}

local repo = arg[1]
if not repo then
   io.stderr:write("usage: ensure-labels.tl <owner/repo>\n")
   os.exit(1)
end

for _, label in ipairs(labels) do
   os.execute("gh label create " .. label .. " --repo " .. repo .. " --force 2>/dev/null")
end
