-- lib/work/render.tl: render a skill template with variables
--
-- usage: render.tl --template <file> [--var key=value]... [--var-file key=path]...
--                  [--json-vars <file>]...
--
-- reads a skill template, strips frontmatter, interpolates {key} placeholders.
-- --var sets a literal value. --var-file reads value from a file.
-- --json-vars reads a json object and sets vars from its string/number fields.
-- special var "repo_root" defaults to cwd if not set.

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

local template_file: string
local vars: {string:string} = {}

local longopts = {
   {name = "template", has_arg = "required", short = "t"},
   {name = "var", has_arg = "required", short = "v"},
   {name = "var-file", has_arg = "required", short = "f"},
   {name = "json-vars", has_arg = "required", short = "j"},
}
local parser = getopt.new(arg, "t:v:f:j:", longopts)

while true do
   local opt, optarg = parser:next()
   if not opt then break end
   if opt == "t" or opt == "template" then
      template_file = optarg
   elseif opt == "v" or opt == "var" then
      local k, v = optarg:match("^([^=]+)=(.*)$")
      if not k then
         io.stderr:write("invalid --var, expected key=value: " .. optarg .. "\n")
         os.exit(1)
      end
      vars[k] = v
   elseif opt == "f" or opt == "var-file" then
      local k, path = optarg:match("^([^=]+)=(.*)$")
      if not k then
         io.stderr:write("invalid --var-file, expected key=path: " .. optarg .. "\n")
         os.exit(1)
      end
      local content = read_file(path)
      if not content then
         io.stderr:write("could not read " .. path .. "\n")
         os.exit(1)
      end
      vars[k] = content
   elseif opt == "j" or opt == "json-vars" then
      local jraw = read_file(optarg)
      if not jraw then
         io.stderr:write("could not read " .. optarg .. "\n")
         os.exit(1)
      end
      local jdata = json.decode(jraw) as {string:any}
      if not jdata then
         io.stderr:write("could not parse " .. optarg .. "\n")
         os.exit(1)
      end
      for jk, jv in pairs(jdata) do
         if type(jv) == "string" then
            vars[jk] = jv as string
         elseif type(jv) == "number" then
            vars[jk] = tostring(jv)
         end
      end
   elseif opt == "?" then
      io.stderr:write("usage: render.tl --template <file> [--var key=value]... [--var-file key=path]...\n")
      os.exit(1)
   end
end

if not template_file then
   io.stderr:write("usage: render.tl --template <file> [--var key=value]... [--var-file key=path]...\n")
   os.exit(1)
end

-- default repo_root to cwd
if not vars["repo_root"] then
   local p = io.popen("pwd")
   if p then
      vars["repo_root"] = p:read("*l") or "."
      p:close()
   else
      vars["repo_root"] = "."
   end
end

local template = read_file(template_file)
if not template then
   io.stderr:write("could not read " .. template_file .. "\n")
   os.exit(1)
end

template = strip_frontmatter(template)
io.write(interpolate(template, vars))
