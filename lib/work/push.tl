-- lib/work/push.tl: push work branch to origin
-- reads branch name from branch.txt file argument

local function read_file(path: string): string
   local f = io.open(path, "r")
   if not f then return nil end
   local content = f:read("*a")
   f:close()
   return content
end

local function run(cmd: string): boolean
   local rc = os.execute(cmd)
   return rc == 0 or rc == true
end

local branch_file = arg[1]
if not branch_file then
   io.stderr:write("usage: push.tl <branch.txt>\n")
   os.exit(1)
end

local branch_content = read_file(branch_file)
if not branch_content then
   io.stderr:write("could not read " .. branch_file .. "\n")
   os.exit(1)
end

local branch = branch_content:gsub("%s+$", "")

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
