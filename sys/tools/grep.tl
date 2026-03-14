-- sys/tools/grep.tl: grep tool for searching files
local child = require("cosmic.child")

return {
  name = "grep",
  description = "Search files for a pattern using grep",
  autoload = false,
  system_prompt = "Use grep to search for patterns in files. Supports -r (recursive), -n (line numbers), -l (files only), -i (case insensitive), -w (word match).",
  input_schema = {
    type = "object",
    properties = {
      pattern = {type = "string", description = "Search pattern (basic regex)"},
      path = {type = "string", description = "File or directory to search (default: .)"},
      flags = {type = "string", description = "Additional grep flags, e.g. '-rn', '-ril', '-w' (default: -rn)"},
    },
    required = {"pattern"},
  },
  execute = function(input: {string: any}): string, boolean
    local pattern = input.pattern as string
    if not pattern or pattern == "" then
      return "error: pattern is required", true
    end

    local path = (input.path as string) or "."
    local flags = (input.flags as string) or "-rn"

    local argv = {"grep", flags, "--", pattern, path}
    local handle, err = child.spawn(argv)
    if not handle then
      return "error: " .. (err or "spawn failed"), true
    end

    handle.stderr:read()
    local _, stdout_raw, exit_str = handle:read()
    local stdout = (stdout_raw as string) or ""
    local exit_code = (tonumber(exit_str) or 0) as integer

    -- grep exits 1 for no matches, 2+ for errors
    if exit_code >= 2 then
      return "error: grep failed (exit " .. exit_code .. ")", true
    end

    if stdout == "" then
      return "no matches found", false
    end

    return stdout, false
  end,
}
