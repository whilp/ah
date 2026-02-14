-- lib/work/labels.tl: ensure required labels exist in the repo
-- reads: WORK_REPO

local labels = {"todo", "doing", "done", "failed", "friction"}

local repo = os.getenv("WORK_REPO")
if not repo or repo == "" then
   io.stderr:write("error: WORK_REPO not set\n")
   os.exit(1)
end

for _, label in ipairs(labels) do
   os.execute("gh label create " .. label .. " --repo " .. repo .. " --force 2>/dev/null")
end
