-- sys/tools/write.tl: write file tool
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local protect = require("ah.protect")
local pathutil = require("ah.pathutil")

return {
  name = "write",
  description = "Write content to a file (creates or overwrites)",
  system_prompt = "Output plain text directly — do not use cat or bash to display what you wrote.\nPrefer editing existing files over creating new ones.",
  input_schema = {
    type = "object",
    properties = {
      path = {type = "string", description = "Path to file to write"},
      content = {type = "string", description = "Content to write"},
    },
    required = {"path", "content"},
  },
  execute = function(input: {string: any}): string, boolean, any
    local file_path = input.path as string
    local content = input.content as string

    if not file_path then
      return "error: path is required", true
    end
    if not content then
      return "error: content is required", true
    end

    if protect.is_protected(file_path) then
      return "error: path is in a protected directory: " .. file_path, true
    end

    pathutil.warn_if_outside_cwd(file_path, "write")

    local dir = fs.dirname(file_path)
    if dir and dir ~= "" then
      local mk_ok, mk_err = fs.makedirs(dir)
      if not mk_ok then
        return "error: failed to create directory: " .. dir .. ": " .. (mk_err or ""), true
      end
    end

    local ok = cio.barf(file_path, content, tonumber("644", 8))
    if not ok then
      return "error: failed to write file: " .. file_path, true
    end

    -- Return written content with line numbers (same format as read tool)
    local all_lines: {string} = {}
    for line in content:gmatch("[^\n]*") do
      table.insert(all_lines, line)
    end
    if #all_lines > 0 and all_lines[#all_lines] == "" and content:sub(-1) == "\n" then
      table.remove(all_lines)
    end
    local numbered: {string} = {}
    for i = 1, #all_lines do
      table.insert(numbered, string.format("%d\t%s", i, all_lines[i]))
    end

    return table.concat(numbered, "\n"), false,
    {path = file_path, bytes = #content, line_count = #all_lines}
  end,
}
