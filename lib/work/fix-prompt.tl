-- lib/work/fix-prompt.tl: build fix prompt from plan.md and check.md
local json = require("cosmic.json")

local function read_file(path: string): string
   local f = io.open(path, "r")
   if not f then return nil end
   local content = f:read("*a")
   f:close()
   return content
end

local function strip_frontmatter(content: string): string
   if content:sub(1, 4) == "---\n" then
      local end_pos = content:find("\n---\n", 5, true)
      if end_pos then
         return content:sub(end_pos + 5)
      end
   end
   return content
end

local function interpolate(template: string, vars: {string:string}): string
   for key, value in pairs(vars) do
      template = template:gsub("{" .. key .. "}", function(): string return value end)
   end
   return template
end

local function extract_branch(plan: string, issue_number: string): string
   return plan:match("Branch: ([^\n]+)") or ("work/" .. issue_number)
end

-- args: issue.json plan.md check.md
local issue_file = arg[1]
local plan_file = arg[2]
local check_file = arg[3]
if not issue_file or not plan_file or not check_file then
   io.stderr:write("usage: fix-prompt.tl <issue.json> <plan.md> <check.md>\n")
   os.exit(1)
end

local issue_raw = read_file(issue_file)
if not issue_raw then
   io.stderr:write("could not read " .. issue_file .. "\n")
   os.exit(1)
end
local issue = json.decode(issue_raw) as {string:any}

local plan = read_file(plan_file)
if not plan then
   io.stderr:write("could not read " .. plan_file .. "\n")
   os.exit(1)
end

local check_contents = read_file(check_file)
if not check_contents then
   io.stderr:write("could not read " .. check_file .. "\n")
   os.exit(1)
end

local template = read_file("sys/skills/fix.md")
if not template then
   io.stderr:write("could not read sys/skills/fix.md\n")
   os.exit(1)
end
template = strip_frontmatter(template)

local cwd = "."
local p = io.popen("pwd")
if p then
   cwd = p:read("*l") or "."
   p:close()
end

local branch = extract_branch(plan, tostring(issue.number))

local result = interpolate(template, {
   title = (issue.title or "") as string,
   ["plan.md contents"] = plan,
   ["check.md contents"] = check_contents,
   branch = branch,
   repo_root = cwd,
})

io.write(result)
