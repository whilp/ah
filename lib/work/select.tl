-- lib/work/select.tl: select highest priority issue from issues.json on stdin
local json = require("cosmic.json")

local record Label
   name: string
end

local record RawIssue
   number: integer
   title: string
   body: string
   url: string
   labels: {Label}
   createdAt: string
end

local function get_priority(labels: {Label}): integer
   for _, label in ipairs(labels) do
      if label.name == "p0" then return 0 end
      if label.name == "p1" then return 1 end
      if label.name == "p2" then return 2 end
   end
   return 3
end

local input = io.read("*a")
if not input or input == "" then
   io.stderr:write("no input\n")
   os.exit(1)
end

local issues = json.decode(input) as {RawIssue}
if not issues or #issues == 0 then
   io.stderr:write("no issues\n")
   os.exit(1)
end

-- sort by priority then creation date
table.sort(issues, function(a: RawIssue, b: RawIssue): boolean
   local ap = get_priority(a.labels)
   local bp = get_priority(b.labels)
   if ap ~= bp then return ap < bp end
   return a.createdAt < b.createdAt
end)

local selected = issues[1]
local issue = {
   number = selected.number,
   title = selected.title,
   body = selected.body,
   url = selected.url,
}

io.write(json.encode(issue))
