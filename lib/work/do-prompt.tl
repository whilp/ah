-- lib/work/do-prompt.tl: build do prompt from issue.json and plan.md
local json = require("cosmic.json")
local getopt = require("cosmic.getopt")

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

local issue_file: string
local plan_file: string

local longopts = {
   {name = "issue", has_arg = "required", short = "i"},
   {name = "plan", has_arg = "required", short = "p"},
}
local parser = getopt.new(arg, "i:p:", longopts)

while true do
   local opt, optarg = parser:next()
   if not opt then break end
   if opt == "i" or opt == "issue" then
      issue_file = optarg
   elseif opt == "p" or opt == "plan" then
      plan_file = optarg
   elseif opt == "?" then
      io.stderr:write("usage: do-prompt.tl --issue <issue.json> --plan <plan.md>\n")
      os.exit(1)
   end
end

if not issue_file or not plan_file then
   io.stderr:write("usage: do-prompt.tl --issue <issue.json> --plan <plan.md>\n")
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

local template = read_file("sys/skills/do.md")
if not template then
   io.stderr:write("could not read sys/skills/do.md\n")
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
   branch = branch,
   repo_root = cwd,
})

io.write(result)
