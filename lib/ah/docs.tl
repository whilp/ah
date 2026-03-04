-- ah/docs.tl: docs subcommand — search embedded documentation
local fs = require("cosmic.fs")
local cio = require("cosmic.io")

local docs_dir = "/zip/embed/sys/docs"

-- collect_doc_files returns sorted list of .md filenames in the docs dir.
-- Returns nil if the docs dir is not accessible.
local function collect_doc_files(): {string}
  local dh = fs.opendir(docs_dir)
  if not dh then return nil end

  local files: {string} = {}
  while true do
    local entry = dh:read()
    if not entry then break end
    if entry ~= "." and entry ~= ".." and entry:match("%.md$") then
      table.insert(files, entry)
    end
  end
  dh:close()
  table.sort(files)
  return files
end

-- cmd_docs implements `ah docs [query]`.
-- Without a query, lists available documentation topics.
-- With a query, searches all docs for matching lines and prints context.
local function cmd_docs(remaining: {string}): integer
  local files = collect_doc_files()
  if not files then
    io.stderr:write("docs: no embedded documentation available\n")
    return 1
  end

  local query = remaining[2]
  if not query then
    -- List mode
    io.write("available documentation:\n")
    for _, fname in ipairs(files) do
      local topic = fname:gsub("%.md$", "")
      io.write("  " .. topic .. "\n")
    end
    io.write("\nusage: ah docs <query>\n")
    return 0
  end

  -- Search mode
  local query_lower = query:lower()
  local match_count = 0
  local max_matches = 20

  for _, fname in ipairs(files) do
    local fpath = docs_dir .. "/" .. fname
    local content = cio.slurp(fpath)
    if content then
      local topic = fname:gsub("%.md$", "")
      local lines: {string} = {}
      for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line)
      end

      local i = 1
      while i <= #lines and match_count < max_matches do
        local line = lines[i]
        if line:lower():find(query_lower, 1, true) then
          -- Find enclosing heading by scanning backwards
          local heading = "[" .. topic .. "]"
          for h = i, 1, -1 do
            if lines[h]:match("^#") then
              heading = "[" .. topic .. "] " .. lines[h]
              break
            end
          end
          io.write(heading .. "\n")
          -- Print matched line + up to 4 following context lines
          local ctx_end = math.min(i + 4, #lines)
          for ci = i, ctx_end do
            io.write("  " .. lines[ci] .. "\n")
          end
          io.write("\n")
          match_count = match_count + 1
          i = ctx_end + 1
        else
          i = i + 1
        end
      end
    end
  end

  if match_count == 0 then
    io.write("no documentation found matching: " .. query .. "\n")
  end
  return 0
end

return {
  cmd_docs = cmd_docs,
}
