-- sys/tools/edit.tl: edit file tool
local cio = require("cosmic.io")

return {
  name = "edit",
  description = "Replace text in a file (old_string must be unique)",
  system_prompt = "The old_string in edit must match the file contents exactly, including whitespace and indentation.\nIf an edit fails with \"old_string is not unique\", re-read the file and include more surrounding context lines in old_string to disambiguate.\nDo not use sed to edit files.",
  input_schema = {
    type = "object",
    properties = {
      path = {type = "string", description = "Path to file to edit"},
      old_string = {type = "string", description = "Text to find and replace"},
      new_string = {type = "string", description = "Replacement text"},
    },
    required = {"path", "old_string", "new_string"},
  },
  execute = function(input: {string: any}): string, boolean, any
    local file_path = input.path as string
    local old_string = input.old_string as string
    local new_string = input.new_string as string

    if not file_path then
      return "error: path is required", true
    end
    if not old_string then
      return "error: old_string is required", true
    end
    if new_string == nil then
      return "error: new_string is required", true
    end

    local content = cio.slurp(file_path)
    if not content then
      return "error: failed to read file: " .. file_path, true
    end

    local _, count = content:gsub(old_string:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1"), "")
    if count == 0 then
      return "error: old_string not found in file", true
    end
    if count > 1 then
      return "error: old_string is not unique (found " .. count .. " times)", true
    end

    local old_lines = 1
    for _ in old_string:gmatch("\n") do old_lines = old_lines + 1 end
    local new_lines = 1
    for _ in new_string:gmatch("\n") do new_lines = new_lines + 1 end

    local escaped_new = new_string:gsub("%%", "%%%%")
    local new_content = content:gsub(old_string:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1"), escaped_new, 1)

    local ok = cio.barf(file_path, new_content, tonumber("644", 8))
    if not ok then
      return "error: failed to write file: " .. file_path, true
    end

    local diff_lines: {string} = {}
    for line in old_string:gmatch("([^\n]*)\n?") do
      if line ~= "" or old_string:find("\n") then
        table.insert(diff_lines, "- " .. line)
      end
    end
    if #diff_lines > 0 and diff_lines[#diff_lines] == "- " and not old_string:match("\n$") then
      table.remove(diff_lines)
    end
    for line in new_string:gmatch("([^\n]*)\n?") do
      if line ~= "" or new_string:find("\n") then
        table.insert(diff_lines, "+ " .. line)
      end
    end
    if #diff_lines > 0 and diff_lines[#diff_lines] == "+ " and not new_string:match("\n$") then
      table.remove(diff_lines)
    end
    local result = table.concat(diff_lines, "\n")
    if result == "" then
      result = "edited " .. file_path
    end

    return result, false, {path = file_path, old_lines = old_lines, new_lines = new_lines}
  end,
}
