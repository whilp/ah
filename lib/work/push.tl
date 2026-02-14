-- lib/work/push.tl: push work branch to origin
-- reads: WORK_BRANCH

local function run(cmd: string): boolean
   local rc = os.execute(cmd)
   return rc == 0 or rc == true
end

local branch = os.getenv("WORK_BRANCH")
if not branch or branch == "" then
   io.stderr:write("error: WORK_BRANCH not set\n")
   os.exit(1)
end

-- check if there are commits ahead of main
if not run("git rev-parse --verify HEAD~1 >/dev/null 2>&1") then
   -- no parent commit, nothing to push
   os.exit(0)
end

-- check if there are actual changes
if run("git diff --quiet origin/main...HEAD") then
   -- no changes
   os.exit(0)
end

-- push
if not run("git push -u origin HEAD:" .. branch) then
   io.stderr:write("git push failed for branch " .. branch .. "\n")
   os.exit(1)
end
