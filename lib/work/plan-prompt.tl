-- lib/work/plan-prompt.tl: build plan prompt from issue.json and template
local json = require("cosmic.json")

local function strip_frontmatter(content: string): string
   if content:sub(1, 4) == "---\n" then
      local end_pos = content:find("\n---\n", 5, true)
      if end_pos then
         return content:sub(end_pos + 5)
      end
   end
   return content
end

local function read_file(path: string): string
   local f = io.open(path, "r")
   if not f then return nil end
   local content = f:read("*a")
   f:close()
   return content
end

local function interpolate(template: string, vars: {string:string}): string
   for key, value in pairs(vars) do
      template = template:gsub("{" .. key .. "}", function(): string return value end)
   end
   return template
end

-- read issue from argument
local issue_file = arg[1]
if not issue_file then
   io.stderr:write("usage: plan-prompt.tl <issue.json>\n")
   os.exit(1)
end

local issue_raw = read_file(issue_file)
if not issue_raw then
   io.stderr:write("could not read " .. issue_file .. "\n")
   os.exit(1)
end

local issue = json.decode(issue_raw) as {string:any}
if not issue then
   io.stderr:write("could not parse " .. issue_file .. "\n")
   os.exit(1)
end

-- read template from skills
local template = read_file("sys/skills/plan.md")
if not template then
   io.stderr:write("could not read sys/skills/plan.md\n")
   os.exit(1)
end

template = strip_frontmatter(template)

local cwd = "."
local p = io.popen("pwd")
if p then
   cwd = p:read("*l") or "."
   p:close()
end

local result = interpolate(template, {
   title = (issue.title or "") as string,
   body = (issue.body or "") as string,
   issue_number = tostring(issue.number),
   repo_root = cwd,
})

io.write(result)
