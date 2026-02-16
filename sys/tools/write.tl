-- sys/tools/write.tl: write file tool
local fs = require("cosmic.fs")
local cio = require("cosmic.io")

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
  execute = function(input: {string:any}): string, boolean, any
    local file_path = input.path as string
    local content = input.content as string

    if not file_path then
      return "error: path is required", true
    end
    if not content then
      return "error: content is required", true
    end

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

    local line_count = 1
    for _ in content:gmatch("\n") do line_count = line_count + 1 end

    return string.format("%d lines", line_count), false,
      {path = file_path, bytes = #content, line_count = line_count}
  end,
}
