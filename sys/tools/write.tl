-- sys/tools/write.tl: write file tool
local fs = require("cosmic.fs")
local cio = require("cosmic.io")

local function is_protected(path: string): boolean
  local protect_env = os.getenv("AH_PROTECT_DIRS") or ""
  if protect_env == "" then return false end
  local cwd = fs.getcwd() or ""
  local abs_path: string
  if path:sub(1, 1) == "/" then
    abs_path = path
  else
    abs_path = cwd .. "/" .. path
  end
  for dir in protect_env:gmatch("[^:]+") do
    local abs_dir: string
    if dir:sub(1, 1) == "/" then
      abs_dir = dir
    else
      abs_dir = cwd .. "/" .. dir
    end
    if abs_path == abs_dir or abs_path:sub(1, #abs_dir + 1) == abs_dir .. "/" then
      return true
    end
  end
  return false
end

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

    if is_protected(file_path) then
      return "error: path is in a protected directory: " .. file_path, true
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
