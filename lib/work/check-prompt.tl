-- lib/work/check-prompt.tl: build check prompt from plan.md and do.md
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

local plan_file: string
local do_file: string

local longopts = {
   {name = "plan", has_arg = "required", short = "p"},
   {name = "do-file", has_arg = "required", short = "d"},
}
local parser = getopt.new(arg, "p:d:", longopts)

while true do
   local opt, optarg = parser:next()
   if not opt then break end
   if opt == "p" or opt == "plan" then
      plan_file = optarg
   elseif opt == "d" or opt == "do-file" then
      do_file = optarg
   elseif opt == "?" then
      io.stderr:write("usage: check-prompt.tl --plan <plan.md> --do-file <do.md>\n")
      os.exit(1)
   end
end

if not plan_file or not do_file then
   io.stderr:write("usage: check-prompt.tl --plan <plan.md> --do-file <do.md>\n")
   os.exit(1)
end

local plan = read_file(plan_file)
if not plan then
   io.stderr:write("could not read " .. plan_file .. "\n")
   os.exit(1)
end

local do_contents = read_file(do_file)
if not do_contents then
   io.stderr:write("could not read " .. do_file .. "\n")
   os.exit(1)
end

local template = read_file("sys/skills/check.md")
if not template then
   io.stderr:write("could not read sys/skills/check.md\n")
   os.exit(1)
end
template = strip_frontmatter(template)

local result = interpolate(template, {
   ["plan.md contents"] = plan,
   ["do.md contents"] = do_contents,
})

io.write(result)
