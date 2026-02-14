-- lib/work/push.tl: push work branch to origin
local getopt = require("cosmic.getopt")

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

local branch_file: string

local longopts = {
   {name = "branch-file", has_arg = "required", short = "b"},
}
local parser = getopt.new(arg, "b:", longopts)

while true do
   local opt, optarg = parser:next()
   if not opt then break end
   if opt == "b" or opt == "branch-file" then
      branch_file = optarg
   elseif opt == "?" then
      io.stderr:write("usage: push.tl --branch-file <branch.txt>\n")
      os.exit(1)
   end
end

if not branch_file then
   io.stderr:write("usage: push.tl --branch-file <branch.txt>\n")
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
