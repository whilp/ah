-- sys/tools/grep.tl: grep tool for searching files
--
-- searches for patterns in files and returns matching lines with line numbers.
-- useful for locating function definitions without reading entire files.

local child = require("cosmic.child")

local function run(argv: {string}): boolean | string, string, number
  local h, err = child.spawn(argv, {
      stderr = 1,
    })
  if not h then
    return false, err or "spawn failed", -1
  end
  return h:read()
end

return {
  name = "grep",
  description = "Search for a pattern in files using grep. Returns matching lines with file paths and line numbers.",
  system_prompt = "Use grep to find function definitions, variable names, or patterns without reading entire files. Returns file:line:content format.",
  input_schema = {
    type = "object",
    properties = {
      pattern = {type = "string", description = "Search pattern (extended regex)"},
      path = {type = "string", description = "Optional directory or file path to search (defaults to current directory)"},
    },
    required = {"pattern"},
  },
  execute = function(input: {string: any}): string
    local pattern = input.pattern as string
    if not pattern or pattern == "" then
      return "error: pattern required"
    end

    -- default to current directory if no path provided
    local search_path = (input.path as string) or "."
    
    -- reject path traversal
    if search_path:match("%.%.") then
      return "error: path must not contain '..'"
    end

    local ok, out, code = run({
        "grep", "-rn", "-E",
        "--include=*.tl",
        "--include=*.lua",
        "--include=*.md",
        "--include=*.yml",
        "--include=*.yaml",
        "--include=*.json",
        "--include=Makefile",
        "--include=*.mk",
        "-e", pattern,
        search_path,
      })

    if not ok then
      if code == 1 then
        return "no matches found"
      end
      return "error: grep failed (exit " .. tostring(code) .. "): " .. (out or "")
    end

    -- truncate long output
    local result = out or ""
    local max_len = 10000
    if #result > max_len then
      result = result:sub(1, max_len) .. "\n... (truncated)"
    end

    return result
  end,
}
